const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const { RtcTokenBuilder, RtcRole } = require("agora-token");

initializeApp();
const db = getFirestore();

// ───────────────────────────────────────────────────────────────────
//  Configuración global
// ───────────────────────────────────────────────────────────────────

/**
 * Lista hardcoded de super-admins por email.
 * Cualquier email aquí puede llamar funciones administrativas.
 * Mantener corto.
 */
const SUPER_ADMIN_EMAILS = ["brealpeaymara@gmail.com"];

const AGORA_APP_ID = defineSecret("AGORA_APP_ID");
const AGORA_APP_CERTIFICATE = defineSecret("AGORA_APP_CERTIFICATE");
const GEMINI_API_KEY = defineSecret("GEMINI_API_KEY");
// Credenciales SMTP propias para enviar el correo de recuperación de
// contraseña. Usamos Gmail con App Password para máxima entregabilidad
// (los correos de noreply@taxis-f0f51.firebaseapp.com llegan a spam).
//
// Setup (una sola vez):
//   1. Activar 2FA en cuenta Gmail.
//   2. https://myaccount.google.com/apppasswords → crear "taxis app".
//   3. firebase functions:secrets:set GMAIL_USER  (= correo Gmail)
//      firebase functions:secrets:set GMAIL_APP_PASSWORD  (= app password 16 chars)
const GMAIL_USER = defineSecret("GMAIL_USER");
const GMAIL_APP_PASSWORD = defineSecret("GMAIL_APP_PASSWORD");

// ───────────────────────────────────────────────────────────────────
//  Helpers
// ───────────────────────────────────────────────────────────────────

function requireAuth(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Debes iniciar sesión.");
  }
  return request.auth;
}

function requireSuperAdmin(request) {
  const auth = requireAuth(request);
  const email = auth.token.email;
  if (!email || !SUPER_ADMIN_EMAILS.includes(email)) {
    throw new HttpsError(
      "permission-denied",
      "Solo el super-admin puede ejecutar esta operación."
    );
  }
  return auth;
}

// ───────────────────────────────────────────────────────────────────
//  generateAgoraToken — token RTC para walkie-talkie
// ───────────────────────────────────────────────────────────────────

exports.generateAgoraToken = onCall(
  {
    secrets: [AGORA_APP_ID, AGORA_APP_CERTIFICATE],
    enforceAppCheck: false,
  },
  (request) => {
    requireAuth(request);

    const { channelName, uid = 0 } = request.data || {};

    if (!channelName || typeof channelName !== "string") {
      throw new HttpsError(
        "invalid-argument",
        "Se requiere channelName (string)."
      );
    }
    if (channelName.length > 64) {
      throw new HttpsError(
        "invalid-argument",
        "channelName demasiado largo (máx 64 caracteres)."
      );
    }
    if (typeof uid !== "number" || uid < 0 || !Number.isInteger(uid)) {
      throw new HttpsError(
        "invalid-argument",
        "uid debe ser un entero >= 0."
      );
    }

    const appId = AGORA_APP_ID.value();
    const appCertificate = AGORA_APP_CERTIFICATE.value();

    if (!appId || !appCertificate) {
      throw new HttpsError(
        "failed-precondition",
        "AGORA_APP_ID/AGORA_APP_CERTIFICATE no están configurados en el servidor."
      );
    }

    const expirationTimeInSeconds = 86400;
    const currentTimestamp = Math.floor(Date.now() / 1000);
    const privilegeExpiredTs = currentTimestamp + expirationTimeInSeconds;

    const token = RtcTokenBuilder.buildTokenWithUid(
      appId,
      appCertificate,
      channelName,
      uid,
      RtcRole.PUBLISHER,
      privilegeExpiredTs,
      privilegeExpiredTs
    );

    return { appId, token, expiresAt: privilegeExpiredTs };
  }
);

// ───────────────────────────────────────────────────────────────────
//  syncUserClaims — sincroniza associationId y role en custom claims
//
//  Se dispara cada vez que se escribe `users/{uid}`. Lee
//  associationId y role del documento y los pone en el JWT del usuario.
//  El cliente debe llamar a `getIdToken(true)` para refrescar.
// ───────────────────────────────────────────────────────────────────

exports.syncUserClaims = onDocumentWritten(
  "users/{uid}",
  async (event) => {
    const uid = event.params.uid;
    const after = event.data?.after?.data();

    // Si se eliminó el doc, limpiar claims.
    if (!after) {
      try {
        await getAuth().setCustomUserClaims(uid, null);
      } catch (e) {
        console.warn(`syncUserClaims: no pude limpiar claims de ${uid}`, e);
      }
      return;
    }

    const associationId = after.associationId || null;
    const role = after.role || "conductor";
    const status = after.status || "active";

    // Detectar super-admin por email
    let isSuperAdmin = false;
    try {
      const userRecord = await getAuth().getUser(uid);
      if (userRecord.email && SUPER_ADMIN_EMAILS.includes(userRecord.email)) {
        isSuperAdmin = true;
      }
    } catch (e) {
      console.warn(`syncUserClaims: no pude leer email de ${uid}`, e);
    }

    const claims = { associationId, role, status };
    if (isSuperAdmin) claims.superAdmin = true;

    try {
      await getAuth().setCustomUserClaims(uid, claims);
      console.log(`syncUserClaims: claims actualizados para ${uid}`, claims);
    } catch (e) {
      console.error(`syncUserClaims: falló para ${uid}`, e);
    }
  }
);

// ───────────────────────────────────────────────────────────────────
//  mirrorExpenseToCashflow — espeja gastos de conductores al cashflow
//  del admin como egresos. Se sincroniza en create, update y delete.
// ───────────────────────────────────────────────────────────────────

exports.mirrorExpenseToCashflow = onDocumentWritten(
  {
    document: "expenses/{expenseId}",
    region: "us-central1",
  },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    const expenseId = event.params.expenseId;

    // Buscar el cashflow vinculado existente (puede ser null en create)
    const linkedSnap = await db.collection("cashflow")
      .where("linkedExpenseId", "==", expenseId)
      .limit(1)
      .get();
    const linked = linkedSnap.empty ? null : linkedSnap.docs[0];

    // CASO 1: expense borrado → borrar cashflow vinculado
    if (!after) {
      if (linked) await linked.ref.delete();
      return;
    }

    // CASO 2: expense creado o actualizado → crear/actualizar cashflow
    // Necesitamos associationId del driver para escribir el cashflow
    // bajo el tenant correcto. Si el expense no tiene associationId
    // (docs viejos), leerlo del user/driver.
    let aid = after.associationId;
    if (!aid && after.driverId) {
      const uSnap = await db.collection("users").doc(after.driverId).get();
      aid = uSnap.exists ? (uSnap.data().associationId || "") : "";
    }
    if (!aid) {
      console.warn(`[mirrorExpenseToCashflow] expense ${expenseId} sin aid, salteo`);
      return;
    }

    const payload = {
      associationId: aid,
      tipo: "egreso",
      categoria: after.category || "gasto",
      subcategoria: null,
      monto: Number(after.amount || 0),
      fecha: after.date || after.createdAt || FieldValue.serverTimestamp(),
      metodoPago: null,
      beneficiario: null,
      descripcion: after.description || "Gasto del conductor",
      comprobanteUrl: after.receiptUrl || null,
      linkedExpenseId: expenseId,
      autoGenerated: true,
      createdBy: after.driverId || "system",
      updatedAt: FieldValue.serverTimestamp(),
    };

    if (linked) {
      await linked.ref.update(payload);
    } else {
      payload.createdAt = FieldValue.serverTimestamp();
      await db.collection("cashflow").add(payload);
    }
  }
);

// ───────────────────────────────────────────────────────────────────
//  validateAssociationCode — el conductor escribe "JIPI" al
//  registrarse y verificamos que la asociación existe y está activa.
//  Devuelve datos básicos para mostrar en pantalla de confirmación.
// ───────────────────────────────────────────────────────────────────

exports.validateAssociationCode = onCall({}, async (request) => {
  // No requiere auth: se usa antes de crear la cuenta.
  const { code } = request.data || {};

  if (!code || typeof code !== "string") {
    throw new HttpsError("invalid-argument", "Código requerido.");
  }

  const normalized = code.trim().toUpperCase();
  if (normalized.length < 3 || normalized.length > 10) {
    throw new HttpsError(
      "invalid-argument",
      "El código debe tener entre 3 y 10 caracteres."
    );
  }

  const snap = await db
    .collection("associations")
    .where("code", "==", normalized)
    .limit(1)
    .get();

  if (snap.empty) {
    throw new HttpsError("not-found", "Código de asociación no encontrado.");
  }

  const doc = snap.docs[0];
  const data = doc.data();
  const status = data.status || "trial";

  if (status === "suspended" || status === "cancelled") {
    throw new HttpsError(
      "failed-precondition",
      "Esta asociación no está activa actualmente."
    );
  }

  return {
    associationId: doc.id,
    name: data.name,
    city: data.city,
    logoUrl: data?.theme?.logoUrl ?? null,
    primaryColor: data?.theme?.primaryColor ?? "#1565C0",
    code: data.code,
  };
});

// ───────────────────────────────────────────────────────────────────
//  approveDriver — el admin de la asociación aprueba un registro
//  pendiente. Marca user.status = active y registra approvedBy/At.
// ───────────────────────────────────────────────────────────────────

exports.approveDriver = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { driverUid } = request.data || {};

  if (!driverUid || typeof driverUid !== "string") {
    throw new HttpsError("invalid-argument", "driverUid requerido.");
  }

  const driverRef = db.collection("users").doc(driverUid);
  const driverSnap = await driverRef.get();
  if (!driverSnap.exists) {
    throw new HttpsError("not-found", "Conductor no encontrado.");
  }

  const driver = driverSnap.data();
  const aid = driver.associationId;

  // Validar permisos: super-admin O admin/operadora de la misma asociación.
  // Fallback a Firestore porque syncUserClaims aún no está operativo.
  const callerEmail = auth.token.email || "";
  let allowed = SUPER_ADMIN_EMAILS.includes(callerEmail);
  if (!allowed) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const caller = callerSnap.exists ? callerSnap.data() : null;
    if (
      caller &&
      ["admin", "operadora"].includes(caller.role) &&
      caller.associationId === aid
    ) {
      allowed = true;
    }
  }

  if (!allowed) {
    throw new HttpsError(
      "permission-denied",
      "Solo admin u operadora de la asociación pueden aprobar conductores."
    );
  }

  await driverRef.update({
    status: "active",
    approvedBy: auth.uid,
    approvedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  // Si el rol del usuario es 'conductor', garantizamos que también
  // exista un doc en `drivers/` con datos denormalizados para que el
  // mapa, la cola y los servicios de ubicación funcionen. Las reglas
  // Firestore no permiten al propio conductor crear su doc (solo
  // admin/operadora), así que lo creamos acá con Admin SDK.
  //
  // Idempotente: si ya existe un driver doc con userId == driverUid,
  // no creamos otro.
  if (driver.role === "conductor") {
    const existing = await db
      .collection("drivers")
      .where("userId", "==", driverUid)
      .limit(1)
      .get();
    if (existing.empty) {
      await db.collection("drivers").add({
        userId: driverUid,
        associationId: aid,
        driverName: [driver.name, driver.lastname]
          .filter(Boolean).join(" ").trim(),
        vehicleNumber: driver.numeroVehiculo || "",
        plate: driver.placa || "",
        status: "desconectado",
        isActive: true,
        licenseNumber: driver.licenseNumber || "",
        licenseType: driver.licenseType || "",
        licenseExpiry: driver.licenseExpiry || new Date(),
        rating: 5.0,
        totalTrips: 0,
        totalPoints: 0,
        vehicleIds: [],
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      console.log(`approveDriver: driver doc creado para ${driverUid}`);
    }
  }

  // Auto-agregar al usuario aprobado a los canales del tenant que
  // estén marcados como `defaultForRoles` para su rol. Antes el admin
  // tenía que aprobar Y luego entrar al canal y agregarlo a mano —
  // ahora la aprobación implica acceso inmediato al radio por defecto.
  // Idempotente: arrayUnion no duplica si ya está.
  try {
    const channelsSnap = await db
      .collection("channels")
      .where("associationId", "==", aid)
      .get();
    const role = driver.role || "conductor";
    let added = 0;
    for (const ch of channelsSnap.docs) {
      const data = ch.data();
      const defaults = Array.isArray(data.defaultForRoles)
        ? data.defaultForRoles
        : [];
      if (!defaults.includes(role)) continue;
      await ch.ref.update({
        memberIds: FieldValue.arrayUnion(driverUid),
        updatedAt: FieldValue.serverTimestamp(),
      });
      added++;
    }
    if (added > 0) {
      console.log(
        `approveDriver: ${driverUid} agregado a ${added} canal(es) default de rol "${role}"`,
      );
    }
  } catch (e) {
    console.warn(
      `approveDriver: error auto-añadiendo a canales default: ${e.message}`,
    );
  }

  return { ok: true };
});

// ───────────────────────────────────────────────────────────────────
//  rejectDriver — rechaza un registro pendiente.
// ───────────────────────────────────────────────────────────────────

exports.rejectDriver = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { driverUid, reason } = request.data || {};

  if (!driverUid || typeof driverUid !== "string") {
    throw new HttpsError("invalid-argument", "driverUid requerido.");
  }

  const driverRef = db.collection("users").doc(driverUid);
  const driverSnap = await driverRef.get();
  if (!driverSnap.exists) {
    throw new HttpsError("not-found", "Conductor no encontrado.");
  }

  const driver = driverSnap.data();
  const aid = driver.associationId;

  // Validar permisos: super-admin O admin/operadora de la misma asociación.
  const callerEmail = auth.token.email || "";
  let allowed = SUPER_ADMIN_EMAILS.includes(callerEmail);
  if (!allowed) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const caller = callerSnap.exists ? callerSnap.data() : null;
    if (
      caller &&
      ["admin", "operadora"].includes(caller.role) &&
      caller.associationId === aid
    ) {
      allowed = true;
    }
  }

  if (!allowed) {
    throw new HttpsError(
      "permission-denied",
      "Solo admin u operadora de la asociación pueden rechazar."
    );
  }

  await driverRef.update({
    status: "rejected",
    rejectedBy: auth.uid,
    rejectedAt: FieldValue.serverTimestamp(),
    rejectionReason: reason || null,
    updatedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true };
});

// ───────────────────────────────────────────────────────────────────
//  transferAdmin — traspasa el rol "admin" a otro socio de la
//  asociación. El admin saliente baja a "conductor".
//
//  Solo callable por:
//    - el admin actual de esa asociación
//    - el super-admin (rescate)
//
//  Validaciones:
//    - newAdminUid existe y pertenece a la misma asociación
//    - su status es "active"
//
//  Operación atómica: actualiza users/{newAdminUid}.role,
//  users/{oldAdminUid}.role y associations/{aid}.ownerUid.
// ───────────────────────────────────────────────────────────────────

exports.transferAdmin = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { newAdminUid } = request.data || {};

  if (!newAdminUid || typeof newAdminUid !== "string") {
    throw new HttpsError("invalid-argument", "newAdminUid requerido.");
  }

  // Cargar al nuevo admin para conocer su asociación
  const newAdminRef = db.collection("users").doc(newAdminUid);
  const newAdminSnap = await newAdminRef.get();
  if (!newAdminSnap.exists) {
    throw new HttpsError("not-found", "Usuario destino no encontrado.");
  }

  const newAdmin = newAdminSnap.data();
  const aid = newAdmin.associationId;

  if (!aid) {
    throw new HttpsError(
      "failed-precondition",
      "El usuario destino no tiene asociación asignada."
    );
  }

  if (newAdmin.status && newAdmin.status !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "El nuevo admin debe estar activo (no pendiente ni rechazado)."
    );
  }

  // Validar permisos del caller
  const callerEmail = auth.token.email || "";
  const callerRole = auth.token.role;
  const callerAid = auth.token.associationId;

  const isCallerSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);
  const isCallerAdminOfAid = callerRole === "admin" && callerAid === aid;

  // Fallback: si los claims aún no se propagaron, validar leyendo
  // users/{caller.uid}. Necesario hasta que syncUserClaims trigger
  // esté operativo en producción.
  let allowed = isCallerSuper || isCallerAdminOfAid;
  if (!allowed) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const callerData = callerSnap.exists ? callerSnap.data() : null;
    if (
      callerData &&
      callerData.role === "admin" &&
      callerData.associationId === aid
    ) {
      allowed = true;
    }
  }

  if (!allowed) {
    throw new HttpsError(
      "permission-denied",
      "Solo el admin actual o el super-admin pueden transferir."
    );
  }

  // Cargar la asociación para conocer el ownerUid actual
  const aidRef = db.collection("associations").doc(aid);
  const aidSnap = await aidRef.get();
  if (!aidSnap.exists) {
    throw new HttpsError("not-found", `Asociación ${aid} no existe.`);
  }
  const association = aidSnap.data();
  const oldAdminUid = association.ownerUid || null;

  if (oldAdminUid === newAdminUid) {
    throw new HttpsError(
      "failed-precondition",
      "El usuario destino ya es el admin actual."
    );
  }

  // Transferencia atómica.
  // Firestore exige que TODOS los reads vayan ANTES de TODOS los writes
  // dentro de una transacción — por eso resolvemos el read del admin
  // saliente arriba, y recién después emitimos las 3 escrituras.
  const oldAdminRef = (oldAdminUid && oldAdminUid !== newAdminUid)
    ? db.collection("users").doc(oldAdminUid)
    : null;
  await db.runTransaction(async (tx) => {
    // ─── READS primero ───
    let demoteOldAdmin = false;
    if (oldAdminRef) {
      const oldAdminSnap = await tx.get(oldAdminRef);
      demoteOldAdmin = oldAdminSnap.exists;
    }

    // ─── WRITES después ───
    // 1. Promover nuevo admin
    tx.update(newAdminRef, {
      role: "admin",
      updatedAt: FieldValue.serverTimestamp(),
    });

    // 2. Degradar admin saliente a "conductor"
    if (demoteOldAdmin) {
      tx.update(oldAdminRef, {
        role: "conductor",
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    // 3. Actualizar ownerUid de la asociación
    tx.update(aidRef, {
      ownerUid: newAdminUid,
      updatedAt: FieldValue.serverTimestamp(),
    });
  });

  return {
    ok: true,
    associationId: aid,
    newAdminUid,
    oldAdminUid,
    oldAdminDemotedTo: oldAdminUid ? "conductor" : null,
  };
});

// ───────────────────────────────────────────────────────────────────
//  setUserStatus — admin u operadora cambia el status de un socio
//  de su asociación: active / suspended.
//  Útil para activar/desactivar sin necesidad de borrar la cuenta.
// ───────────────────────────────────────────────────────────────────

exports.setUserStatus = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { userUid, status, isActive } = request.data || {};

  if (!userUid || typeof userUid !== "string") {
    throw new HttpsError("invalid-argument", "userUid requerido.");
  }

  const allowedStatus = ["active", "suspended"];
  if (status && !allowedStatus.includes(status)) {
    throw new HttpsError(
      "invalid-argument",
      `status debe ser uno de: ${allowedStatus.join(", ")}`
    );
  }

  const userRef = db.collection("users").doc(userUid);
  const userSnap = await userRef.get();
  if (!userSnap.exists) {
    throw new HttpsError("not-found", "Usuario no encontrado.");
  }
  const userData = userSnap.data();
  const aid = userData.associationId;

  // Validar permisos: super-admin O admin/operadora de la misma asociación
  const callerEmail = auth.token.email || "";
  const isCallerSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);

  let allowed = isCallerSuper;
  if (!allowed) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const callerData = callerSnap.exists ? callerSnap.data() : null;
    if (
      callerData &&
      ["admin", "operadora"].includes(callerData.role) &&
      callerData.associationId === aid
    ) {
      allowed = true;
    }
  }

  if (!allowed) {
    throw new HttpsError("permission-denied", "Sin permisos para esta acción.");
  }

  // Evitar que se desactive al admin actual de la asociación
  if (
    (status === "suspended" || isActive === false) &&
    userData.role === "admin"
  ) {
    throw new HttpsError(
      "failed-precondition",
      "No puedes desactivar al administrador. Transfiere el rol primero."
    );
  }

  const update = { updatedAt: FieldValue.serverTimestamp() };
  if (status) update.status = status;
  if (isActive !== undefined) update.isActive = isActive;

  await userRef.update(update);

  return { ok: true };
});

// ───────────────────────────────────────────────────────────────────
//  deleteUser — borra permanentemente una cuenta (Firestore + Auth).
//  Solo admin de la asociación o super-admin pueden hacerlo.
//
//  Salvaguardas:
//    - No se puede eliminar al admin actual de la asociación
//      (debe transferirse el rol primero).
//    - No se puede eliminar al propio usuario (auto-borrado bloqueado).
// ───────────────────────────────────────────────────────────────────

exports.deleteUser = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { userUid } = request.data || {};

  if (!userUid || typeof userUid !== "string") {
    throw new HttpsError("invalid-argument", "userUid requerido.");
  }

  if (userUid === auth.uid) {
    throw new HttpsError(
      "failed-precondition",
      "No puedes eliminar tu propia cuenta."
    );
  }

  const userRef = db.collection("users").doc(userUid);
  const userSnap = await userRef.get();
  if (!userSnap.exists) {
    throw new HttpsError("not-found", "Usuario no encontrado.");
  }
  const userData = userSnap.data();
  const aid = userData.associationId;

  // Validar permisos: super-admin O admin de la misma asociación
  const callerEmail = auth.token.email || "";
  const isCallerSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);

  let allowed = isCallerSuper;
  if (!allowed) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const callerData = callerSnap.exists ? callerSnap.data() : null;
    if (
      callerData &&
      callerData.role === "admin" &&
      callerData.associationId === aid
    ) {
      allowed = true;
    }
  }

  if (!allowed) {
    throw new HttpsError("permission-denied", "Sin permisos.");
  }

  // No permitir borrar al admin actual de la asociación
  if (userData.role === "admin") {
    throw new HttpsError(
      "failed-precondition",
      "No puedes eliminar al administrador. Transfiere el rol primero."
    );
  }

  // 1) Soft-delete: marcamos el doc en vez de borrarlo, para que los
  //    pagos / viajes / cobros históricos sigan teniendo a quién apuntar
  //    y el admin pueda revisar el balance pendiente del ex-conductor.
  //
  //    Liberamos cédula y email para que SÍ se pueda crear un usuario
  //    nuevo con esos mismos datos:
  //    - cedula → archivedCedula + cedula = "_deleted_<ts>_<original>"
  //    - email  → eliminamos la cuenta Auth (libera el email para re-uso)
  const now = FieldValue.serverTimestamp();
  const ts = Date.now();
  const archivedCedula = userData.cedula || null;
  const archivedEmail = userData.email || null;
  const archivedRole = userData.role || null;

  await userRef.update({
    deletedAt: now,
    deletedBy: auth.uid,
    status: "deleted",
    archivedCedula,
    archivedEmail,
    archivedRole,
    cedula: archivedCedula
      ? `_deleted_${ts}_${archivedCedula}`
      : `_deleted_${ts}`,
    // Apagamos el doc para todas las queries de usuarios activos.
    isActive: false,
    updatedAt: now,
  });

  // 1.b) Cascada al doc en `drivers/`: lo apagamos y borramos posición.
  //      Sin esto, el ex-conductor sigue apareciendo en el mapa y la
  //      operadora ve un fantasma con su última coordenada.
  try {
    const driverRef = db.collection("drivers").doc(userUid);
    const driverSnap = await driverRef.get();
    if (driverSnap.exists) {
      await driverRef.update({
        isActive: false,
        archivedAt: now,
        deletedAt: now,
        // Limpiar posición y status para que ningún cliente lo pinte.
        currentPosition: null,
        currentLat: null,
        currentLng: null,
        currentLatitude: null,
        currentLongitude: null,
        status: "offline",
        inQueueAt: null,
        updatedAt: now,
      });
    }
  } catch (e) {
    console.warn(`deleteUser: no pude apagar drivers/${userUid}`, e);
  }

  // 2) Borrar la cuenta de Firebase Auth (libera el email).
  //    Esto invalida el refresh token, así que el celular zombi pierde
  //    sesión la próxima vez que intente refrescar el ID token (~1h).
  //    El doc en `users/{uid}` con status='deleted' además provoca que
  //    el ClaimsRefreshService del cliente haga signOut inmediato.
  try {
    await getAuth().deleteUser(userUid);
  } catch (e) {
    // Si la cuenta ya no existe en Auth, no es error.
    if (e.code !== "auth/user-not-found") {
      console.warn(`deleteUser: no pude borrar Auth ${userUid}`, e);
    }
  }

  // 3) Revocar refresh tokens — corta la sesión del celular zombi al
  //    próximo intento de refresh, en lugar de esperar la hora del ID
  //    token cacheado. Hacemos esto ANTES de deleteUser fallaría porque
  //    ya no existe; lo intentamos igual y silenciamos el error si
  //    deleteUser ya lo limpió.
  try {
    await getAuth().revokeRefreshTokens(userUid);
  } catch (_) {}

  return {
    ok: true,
    deletedUid: userUid,
    softDeleted: true,
    archivedCedula,
    archivedEmail,
  };
});

// ───────────────────────────────────────────────────────────────────
//  checkCedulaAvailable — verifica si una cédula está disponible
//  para registro. Llamada desde la pantalla de signup ANTES de
//  createUserWithEmailAndPassword: las reglas de Firestore no dejan
//  al usuario recién creado consultar la colección users por cedula
//  (no es owner, no es active, no tiene tenant), así que la query
//  directa fallaba con PERMISSION_DENIED y bloqueaba la registración
//  legítima.
//
//  Esta función:
//  - Es callable SIN autenticación (igual que sendPasswordResetEmail).
//  - Usa Admin SDK que ignora reglas → puede listar users.
//  - Considera "disponibles" las cédulas que no existen O que solo
//    pertenecen a usuarios soft-deleted (deletedAt != null).
// ───────────────────────────────────────────────────────────────────

exports.checkCedulaAvailable = onCall(
  { region: "us-central1" },
  async (request) => {
    const cedula = (request.data?.cedula || "").toString().trim();
    if (!cedula) {
      throw new HttpsError("invalid-argument", "cedula requerida.");
    }
    const snap = await db
      .collection("users")
      .where("cedula", "==", cedula)
      .get();
    let active = 0;
    for (const d of snap.docs) {
      if (!d.data().deletedAt) active++;
    }
    return {
      available: active === 0,
      total: snap.size,
      activeCount: active,
    };
  }
);


// ───────────────────────────────────────────────────────────────────
//  updateUser — admin/operadora actualiza datos de un socio
//  (nombre, teléfono, datos de vehículo, etc.).
//  No permite cambiar role, status, associationId ni email
//  (esos campos requieren funciones específicas).
// ───────────────────────────────────────────────────────────────────

const UPDATABLE_USER_FIELDS = [
  "name",
  "lastname",
  "cedula",
  "phone",
  "photoUrl",
  "placa",
  "cooperativa",
  "codigoCooperativa",
  "numeroVehiculo",
  "fotoVehiculo",
  "fotoLicenciaFrontal",
  "fotoLicenciaTrasera",
];

exports.updateUser = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { userUid, fields } = request.data || {};

  if (!userUid || typeof userUid !== "string") {
    throw new HttpsError("invalid-argument", "userUid requerido.");
  }
  if (!fields || typeof fields !== "object") {
    throw new HttpsError("invalid-argument", "fields requerido.");
  }

  const userRef = db.collection("users").doc(userUid);
  const userSnap = await userRef.get();
  if (!userSnap.exists) {
    throw new HttpsError("not-found", "Usuario no encontrado.");
  }
  const userData = userSnap.data();
  const aid = userData.associationId;

  const callerEmail = auth.token.email || "";
  const isCallerSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);
  const isSelf = userUid === auth.uid;

  let allowed = isCallerSuper || isSelf;
  if (!allowed) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const callerData = callerSnap.exists ? callerSnap.data() : null;
    if (
      callerData &&
      ["admin", "operadora"].includes(callerData.role) &&
      callerData.associationId === aid
    ) {
      allowed = true;
    }
  }

  if (!allowed) {
    throw new HttpsError("permission-denied", "Sin permisos.");
  }

  // Filtrar solo campos permitidos
  const update = { updatedAt: FieldValue.serverTimestamp() };
  for (const k of UPDATABLE_USER_FIELDS) {
    if (fields[k] !== undefined) {
      update[k] = fields[k];
    }
  }

  if (Object.keys(update).length === 1) {
    throw new HttpsError("invalid-argument", "Sin campos para actualizar.");
  }

  await userRef.update(update);

  return { ok: true };
});

// ───────────────────────────────────────────────────────────────────
//  PAGOS DEL CONDUCTOR A LA ASOCIACIÓN
// ───────────────────────────────────────────────────────────────────

const VALID_PAYMENT_CONCEPTS = [
  "cuota_mensual",
  "cuota_semanal",
  "multa",
  "deuda",
  "incentivo",
  "ayuda",
];

const VALID_PAYMENT_METHODS = ["transferencia", "deposito", "efectivo"];

/**
 * Conductor reporta un pago hecho a la asociación. Queda como `pending`
 * hasta que admin/operadora valide.
 *
 * Input: { amount, concept, paymentDate, dueDate?, notes?, proof: {...} }
 *   proof = {
 *     method: 'transferencia'|'deposito'|'efectivo',
 *     bank?, bankOther?, transactionRef?, transactionDate?,
 *     deliveredTo?, photoUrl?
 *   }
 */
exports.reportPayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const data = request.data || {};

  // Cargar al usuario que reporta para validar asociación
  const userSnap = await db.collection("users").doc(auth.uid).get();
  if (!userSnap.exists) {
    throw new HttpsError("not-found", "Usuario no encontrado.");
  }
  const user = userSnap.data();
  const aid = user.associationId;
  if (!aid) {
    throw new HttpsError(
      "failed-precondition",
      "No perteneces a una asociación."
    );
  }

  // Estados que SÍ pueden reportar pago:
  //   - active: operación normal
  //   - paymentBlocked: necesita pagar para desbloquearse (CRÍTICO —
  //     sin esto el conductor bloqueado por mora queda atrapado sin
  //     poder subir comprobante)
  //   - paymentPending: período de gracia
  // Estados que NO pueden:
  //   - pendingApproval, rejected, disabledByAdmin, suspended, deleted
  const allowedToPay = [
    "active",
    "paymentBlocked",
    "paymentPending",
  ];
  const userStatus = user.status || "active";
  if (!allowedToPay.includes(userStatus)) {
    throw new HttpsError(
      "failed-precondition",
      "Tu cuenta no puede reportar pagos en este estado."
    );
  }

  // Validar payload
  const amount = Number(data.amount);
  if (!isFinite(amount) || amount <= 0) {
    throw new HttpsError("invalid-argument", "amount debe ser > 0.");
  }

  const concept = data.concept;
  if (!VALID_PAYMENT_CONCEPTS.includes(concept)) {
    throw new HttpsError(
      "invalid-argument",
      `concept debe ser uno de: ${VALID_PAYMENT_CONCEPTS.join(", ")}`
    );
  }

  const paymentDate = data.paymentDate
    ? new Date(data.paymentDate)
    : new Date();

  const proofIn = data.proof || {};
  const method = proofIn.method;
  if (!VALID_PAYMENT_METHODS.includes(method)) {
    throw new HttpsError(
      "invalid-argument",
      `proof.method debe ser uno de: ${VALID_PAYMENT_METHODS.join(", ")}`
    );
  }

  // Cargar billingConfig de la asociación para resolver retención
  const aidSnap = await db.collection("associations").doc(aid).get();
  const billingConfig = aidSnap.exists
    ? aidSnap.data().billingConfig || {}
    : {};
  const proofRetentionDays = Number(billingConfig.proofRetentionDays || 90);

  // Construir el proof
  const proof = { method };
  if (method === "efectivo") {
    proof.deliveredTo = proofIn.deliveredTo || null;
  } else {
    proof.bank = proofIn.bank || null;
    proof.bankOther =
      proofIn.bank === "Otros" ? proofIn.bankOther || null : null;
    proof.transactionRef = proofIn.transactionRef || null;
    proof.transactionDate = proofIn.transactionDate
      ? new Date(proofIn.transactionDate)
      : null;
  }
  if (proofIn.photoUrl) {
    proof.photoUrl = proofIn.photoUrl;
    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + proofRetentionDays);
    proof.photoExpiresAt = expiresAt;
    proof.photoExpired = false;
  }

  // Si viene un chargeId, el conductor está pagando un cobro one-off
  // emitido previamente por el admin. Validamos ownership y actualizamos
  // el doc existente en vez de crear uno nuevo. Mantiene la trazabilidad
  // emisión → pago → validación en un solo registro.
  if (data.chargeId) {
    const chargeRef = db.collection("payments").doc(String(data.chargeId));
    const chargeSnap = await chargeRef.get();
    if (!chargeSnap.exists) {
      throw new HttpsError("not-found", "El cobro no existe.");
    }
    const charge = chargeSnap.data();
    if (charge.driverId !== auth.uid) {
      throw new HttpsError(
        "permission-denied",
        "Este cobro no es tuyo."
      );
    }
    if (charge.isOneOff !== true) {
      throw new HttpsError(
        "failed-precondition",
        "Solo se puede pagar así un cobro emitido por admin."
      );
    }
    if (charge.proof != null) {
      throw new HttpsError(
        "failed-precondition",
        "Este cobro ya fue reportado."
      );
    }
    if (charge.status !== "pending") {
      throw new HttpsError(
        "failed-precondition",
        "El cobro ya no está en estado pendiente."
      );
    }
    // Denormalizamos por si el doc no traía el nombre (compat con docs
    // creados antes de este cambio).
    const dName = [user.name, user.lastname]
      .filter(Boolean)
      .join(" ")
      .trim() || null;
    await chargeRef.update({
      paymentDate,
      proof,
      reportedAt: FieldValue.serverTimestamp(),
      driverName: dName,
      driverVehicleNumber: user.numeroVehiculo || null,
    });
    return { ok: true, paymentId: chargeRef.id, updatedCharge: true };
  }

  // Denormalizamos nombre + unidad del conductor para que admin/operadora
  // puedan listar pagos sin tener que hacer un lookup adicional por
  // driverId. El usuario lo cargamos arriba en `user`.
  const driverName = [user.name, user.lastname]
    .filter(Boolean)
    .join(" ")
    .trim() || null;
  const driverVehicleNumber = user.numeroVehiculo || null;

  const ref = db.collection("payments").doc();
  await ref.set({
    associationId: aid,
    driverId: auth.uid,
    driverName,
    driverVehicleNumber,
    amount,
    concept,
    status: "pending",
    paymentDate,
    dueDate: data.dueDate ? new Date(data.dueDate) : null,
    notes: data.notes || null,
    proof,
    reportedAt: FieldValue.serverTimestamp(),
    validatedBy: null,
    validatedAt: null,
    rejectionReason: null,
    isOneOff: false,
  });

  return { ok: true, paymentId: ref.id };
});

/**
 * Admin/operadora valida un pago. Cambia status a `validated`.
 */
exports.validatePayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { paymentId } = request.data || {};

  if (!paymentId) {
    throw new HttpsError("invalid-argument", "paymentId requerido.");
  }

  const ref = db.collection("payments").doc(paymentId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Pago no encontrado.");
  }
  const payment = snap.data();

  await _assertCanValidate(auth, payment.associationId);

  if (payment.status !== "pending") {
    throw new HttpsError(
      "failed-precondition",
      `El pago ya está en estado ${payment.status}.`
    );
  }

  await ref.update({
    status: "validated",
    validatedBy: auth.uid,
    validatedAt: FieldValue.serverTimestamp(),
    rejectionReason: null,
  });

  // Si el conductor estaba paymentBlocked por cuota_vencida, reactivar inmediato
  const driverSnap = await db.collection("users").doc(payment.driverId).get();
  if (driverSnap.exists) {
    const d = driverSnap.data();
    if (d.status === "paymentBlocked" && d.blockReason === "cuota_vencida") {
      await driverSnap.ref.update({
        status: "active",
        blockedAt: FieldValue.delete(),
        blockReason: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      console.log(`[validatePayment] auto-reactivated ${payment.driverId}`);
      await _sendFcmToUid(payment.driverId, {
        title: "Cuenta reactivada",
        body: "Tu pago fue aprobado. Ya puedes operar normalmente.",
      }).catch(() => {});
    }
  }

  // Auto-cashflow: cuando se valida un pago, crear espejo de ingreso
  // en cashflow/ para que el balance del admin lo refleje sin doble carga.
  // Vinculado por linkedPaymentId; voidPayment lo borra después.
  // Membresía asociación va al super-admin, no al cashflow del tenant.
  const skipCashflow =
    payment.concept === "membresia_asociacion" ||
    payment.targetSuperAdmin === true;
  if (!skipCashflow) {
    const cashflowRef = db.collection("cashflow").doc();
    let fechaPago = payment.paymentDate || payment.validatedAt || null;
    // Timestamp de Firestore → lo usamos tal cual; si es null usamos serverTimestamp
    await cashflowRef.set({
      associationId: payment.associationId,
      tipo: "ingreso",
      categoria: payment.concept || "cuota",
      subcategoria: null,
      monto: payment.amount,
      fecha: fechaPago || FieldValue.serverTimestamp(),
      metodoPago: (payment.proof && payment.proof.method) ? payment.proof.method : null,
      beneficiario: payment.driverName ||
        (payment.driverVehicleNumber
          ? `Unidad #${payment.driverVehicleNumber}`
          : null),
      descripcion: `Pago validado · ${payment.concept || "cuota"}`,
      comprobanteUrl: (payment.proof && payment.proof.photoUrl) ? payment.proof.photoUrl : null,
      linkedPaymentId: ref.id,
      autoGenerated: true,
      createdBy: auth.uid,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  return { ok: true };
});

// ──────────────────────────────────────────────────────────────────
//  voidPayment — admin anula un pago previamente validado.
//  Bloquea al conductor inmediatamente + FCM con motivo.
// ──────────────────────────────────────────────────────────────────

exports.voidPayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { paymentId, reason } = request.data || {};

  if (!paymentId || typeof paymentId !== "string") {
    throw new HttpsError("invalid-argument", "paymentId requerido.");
  }
  if (!reason || typeof reason !== "string" || reason.length < 10) {
    throw new HttpsError("invalid-argument", "Motivo obligatorio (mín 10 caracteres).");
  }

  const paymentRef = db.collection("payments").doc(paymentId);
  const paymentSnap = await paymentRef.get();
  if (!paymentSnap.exists) {
    throw new HttpsError("not-found", "Pago no existe.");
  }
  const p = paymentSnap.data();

  if (p.status !== "validated" || p.voidedAt) {
    throw new HttpsError("failed-precondition", "Solo se anulan pagos validados (no anulados).");
  }

  // Solo admin del tenant o super-admin (la operadora NO puede anular,
  // solo validar/rechazar pagos pending).
  const callerEmail = auth.token.email || "";
  const isSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);
  if (!isSuper) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const caller = callerSnap.exists ? callerSnap.data() : null;
    if (!caller || caller.role !== "admin" || caller.associationId !== p.associationId) {
      throw new HttpsError(
        "permission-denied",
        "Solo admin del tenant o super-admin pueden anular un pago."
      );
    }
  }

  const now = FieldValue.serverTimestamp();
  await paymentRef.update({
    voidedAt: now,
    voidedBy: auth.uid,
    voidReason: reason,
    updatedAt: now,
  });

  // Bloquear conductor
  if (p.driverId) {
    await db.collection("users").doc(p.driverId).update({
      status: "paymentBlocked",
      blockedAt: now,
      blockReason: "pago_anulado",
      updatedAt: now,
    });
    await _sendFcmToUid(p.driverId, {
      title: "Pago anulado",
      body: `Un pago tuyo fue anulado. Motivo: ${reason}. Tu cuenta está bloqueada.`,
    }).catch(() => {});
  }

  // Si el pago tenía un cashflow vinculado (auto-generado al validar),
  // borrarlo para que el balance del admin no quede inflado con un pago
  // que fue anulado.
  const linkedSnap = await db.collection("cashflow")
    .where("linkedPaymentId", "==", paymentRef.id)
    .limit(5)
    .get();
  for (const d of linkedSnap.docs) {
    await d.ref.delete();
  }

  return { ok: true };
});

// ──────────────────────────────────────────────────────────────────
//  reportAssociationPayment — admin sube comprobante de membresía al
//  super-admin. Crea doc en `payments` con concept='membresia_asociacion'.
// ──────────────────────────────────────────────────────────────────

exports.reportAssociationPayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { amount, bank, transactionRef, transactionDate, photoUrl, photoExpiresAt } = request.data || {};

  if (!amount || amount <= 0) {
    throw new HttpsError("invalid-argument", "Monto inválido.");
  }

  const userSnap = await db.collection("users").doc(auth.uid).get();
  const u = userSnap.data() || {};
  if (u.role !== "admin") {
    throw new HttpsError("permission-denied", "Solo admin puede reportar membresía.");
  }

  const now = FieldValue.serverTimestamp();
  const docRef = db.collection("payments").doc();
  await docRef.set({
    associationId: u.associationId,
    driverId: auth.uid,
    driverName: `${u.name || ""} ${u.lastname || ""}`.trim(),
    concept: "membresia_asociacion",
    amount,
    status: "pending",
    targetSuperAdmin: true,
    reportedAt: now,
    proof: {
      method: "transferencia",
      bank: bank || null,
      transactionRef: transactionRef || null,
      transactionDate: transactionDate ? Timestamp.fromDate(new Date(transactionDate)) : null,
      photoUrl: photoUrl || null,
      photoExpiresAt: photoExpiresAt ? Timestamp.fromDate(new Date(photoExpiresAt)) : null,
    },
    createdAt: now,
    updatedAt: now,
  });

  return { ok: true, paymentId: docRef.id };
});

// ──────────────────────────────────────────────────────────────────
//  validateAssociationPayment — super-admin aprueba pago de membresía.
//  Extiende paidUntil + months, activa asociación, FCM a todos.
// ──────────────────────────────────────────────────────────────────

exports.validateAssociationPayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { paymentId, monthsToAdd } = request.data || {};

  const callerEmail = auth.token.email || "";
  const isSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);
  if (!isSuper) {
    throw new HttpsError("permission-denied", "Solo super-admin.");
  }

  if (!paymentId) throw new HttpsError("invalid-argument", "paymentId requerido.");
  const months = Math.max(1, Math.min(36, Number(monthsToAdd) || 1));

  const pRef = db.collection("payments").doc(paymentId);
  const pSnap = await pRef.get();
  if (!pSnap.exists) throw new HttpsError("not-found", "Pago no existe.");
  const p = pSnap.data();
  if (p.concept !== "membresia_asociacion") {
    throw new HttpsError("failed-precondition", "Este pago no es de membresía.");
  }
  if (p.status !== "pending") {
    throw new HttpsError("failed-precondition", "Solo pagos pendientes.");
  }

  const now = FieldValue.serverTimestamp();
  await pRef.update({
    status: "validated",
    validatedAt: now,
    validatedBy: auth.uid,
    updatedAt: now,
  });

  // Extender paidUntil
  const aRef = db.collection("associations").doc(p.associationId);
  const aSnap = await aRef.get();
  const current = aSnap.data().paidUntil?.toDate?.() || new Date();
  const base = current > new Date() ? current : new Date();
  const newPaidUntil = new Date(base);
  newPaidUntil.setUTCMonth(newPaidUntil.getUTCMonth() + months);

  await aRef.update({
    status: "active",
    paidUntil: Timestamp.fromDate(newPaidUntil),
    suspendedAt: FieldValue.delete(),
    suspendedReason: FieldValue.delete(),
    updatedAt: now,
  });

  // FCM a todos los users de la asoc
  const usersSnap = await db.collection("users")
    .where("associationId", "==", p.associationId)
    .get();
  await Promise.all(usersSnap.docs.map((u) => _sendFcmToUid(u.id, {
    title: "Cooperativa reactivada",
    body: "Ya puedes operar normalmente.",
  }).catch(() => {})));

  return { ok: true, newPaidUntil: newPaidUntil.toISOString() };
});

// ──────────────────────────────────────────────────────────────────
//  extendPaidUntil — super-admin extiende paidUntil manualmente sin
//  comprobante (caso transferencia directa fuera de la app).
// ──────────────────────────────────────────────────────────────────

exports.extendPaidUntil = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { associationId, monthsToAdd } = request.data || {};

  const callerEmail = auth.token.email || "";
  const isSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);
  if (!isSuper) throw new HttpsError("permission-denied", "Solo super-admin.");
  if (!associationId) throw new HttpsError("invalid-argument", "associationId requerido.");
  const months = Math.max(1, Math.min(36, Number(monthsToAdd) || 1));

  const aRef = db.collection("associations").doc(associationId);
  const aSnap = await aRef.get();
  if (!aSnap.exists) throw new HttpsError("not-found", "Asoc no existe.");

  const current = aSnap.data().paidUntil?.toDate?.() || new Date();
  const base = current > new Date() ? current : new Date();
  const newPaidUntil = new Date(base);
  newPaidUntil.setUTCMonth(newPaidUntil.getUTCMonth() + months);

  await aRef.update({
    status: "active",
    paidUntil: Timestamp.fromDate(newPaidUntil),
    suspendedAt: FieldValue.delete(),
    suspendedReason: FieldValue.delete(),
    updatedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true, newPaidUntil: newPaidUntil.toISOString() };
});

/**
 * Admin/operadora rechaza un pago. Cambia status a `rejected` con motivo.
 */
exports.rejectPayment = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { paymentId, reason } = request.data || {};

  if (!paymentId) {
    throw new HttpsError("invalid-argument", "paymentId requerido.");
  }

  const ref = db.collection("payments").doc(paymentId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new HttpsError("not-found", "Pago no encontrado.");
  }
  const payment = snap.data();

  await _assertCanValidate(auth, payment.associationId);

  if (payment.status !== "pending") {
    throw new HttpsError(
      "failed-precondition",
      `El pago ya está en estado ${payment.status}.`
    );
  }

  await ref.update({
    status: "rejected",
    validatedBy: auth.uid,
    validatedAt: FieldValue.serverTimestamp(),
    rejectionReason: reason || null,
  });

  return { ok: true };
});

/**
 * Helper: valida que el caller sea super-admin O admin/operadora de la
 * asociación dada.
 */
async function _assertCanValidate(auth, aid) {
  const callerEmail = auth.token.email || "";
  if (SUPER_ADMIN_EMAILS.includes(callerEmail)) return;

  const callerSnap = await db.collection("users").doc(auth.uid).get();
  const caller = callerSnap.exists ? callerSnap.data() : null;
  if (
    caller &&
    ["admin", "operadora"].includes(caller.role) &&
    caller.associationId === aid
  ) {
    return;
  }

  throw new HttpsError(
    "permission-denied",
    "Solo admin u operadora de la asociación pueden validar/rechazar pagos."
  );
}

/**
 * Admin actualiza el `billingConfig` de su asociación. Solo el admin
 * de esa asociación o super-admin pueden hacerlo.
 */
exports.updateBillingConfig = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { associationId, billingConfig } = request.data || {};

  if (!associationId || typeof associationId !== "string") {
    throw new HttpsError("invalid-argument", "associationId requerido.");
  }
  if (!billingConfig || typeof billingConfig !== "object") {
    throw new HttpsError("invalid-argument", "billingConfig requerido.");
  }

  // Validar permisos
  const callerEmail = auth.token.email || "";
  let allowed = SUPER_ADMIN_EMAILS.includes(callerEmail);
  if (!allowed) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const caller = callerSnap.exists ? callerSnap.data() : null;
    if (
      caller &&
      caller.role === "admin" &&
      caller.associationId === associationId
    ) {
      allowed = true;
    }
  }
  if (!allowed) {
    throw new HttpsError(
      "permission-denied",
      "Solo admin de la asociación o super-admin."
    );
  }

  // Filtrar campos permitidos y validar tipos
  const cleaned = {
    amount: Number(billingConfig.amount) || 0,
    defaultConcept: VALID_PAYMENT_CONCEPTS.includes(billingConfig.defaultConcept)
      ? billingConfig.defaultConcept
      : "cuota_mensual",
    period: {
      every: Number(billingConfig?.period?.every) || 1,
      unit: ["day", "week", "month", "year"].includes(
        billingConfig?.period?.unit
      )
        ? billingConfig.period.unit
        : "month",
    },
    dueDay: Number(billingConfig.dueDay) || 1,
    allowDebtCarryOver: !!billingConfig.allowDebtCarryOver,
    proofRetentionDays: Math.max(
      1,
      Number(billingConfig.proofRetentionDays) || 90
    ),
    allowProofPhoto: billingConfig.allowProofPhoto !== false,
  };

  await db.collection("associations").doc(associationId).update({
    billingConfig: cleaned,
    updatedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true };
});

// ───────────────────────────────────────────────────────────────────
//  createAssociation — solo super-admin puede crear nuevas
//  asociaciones (cuando vendes el SaaS). Devuelve credenciales
//  temporales del primer admin.
// ───────────────────────────────────────────────────────────────────

exports.createAssociation = onCall({}, async (request) => {
  requireSuperAdmin(request);

  const {
    code,
    name,
    city,
    pricingTierId = "basic",
    adminEmail,
    adminPassword, // si no se manda, generamos uno temporal
    adminName = "",
    adminLastname = "",
    phone,
    trialDays = 30,
    theme,
  } = request.data || {};

  if (!code || !name || !city || !adminEmail) {
    throw new HttpsError(
      "invalid-argument",
      "code, name, city y adminEmail son obligatorios."
    );
  }

  const normalizedCode = code.trim().toUpperCase();

  // El code debe ser único globalmente
  const existing = await db
    .collection("associations")
    .where("code", "==", normalizedCode)
    .limit(1)
    .get();
  if (!existing.empty) {
    throw new HttpsError(
      "already-exists",
      `El código ${normalizedCode} ya está en uso.`
    );
  }

  // Slug derivado del code en minúsculas
  const slug = normalizedCode.toLowerCase();
  const aidRef = db.collection("associations").doc(slug);
  if ((await aidRef.get()).exists) {
    throw new HttpsError(
      "already-exists",
      `Ya existe una asociación con slug ${slug}.`
    );
  }

  // Cargar plan
  const tierSnap = await db.collection("pricingTiers").doc(pricingTierId).get();
  if (!tierSnap.exists) {
    throw new HttpsError(
      "not-found",
      `pricingTier ${pricingTierId} no existe.`
    );
  }
  const tier = tierSnap.data();

  // Crear el admin en Firebase Auth (o reutilizar si ya existe)
  let adminUserRecord;
  const tempPassword =
    adminPassword || `taxi-${Math.random().toString(36).substring(2, 10)}`;
  try {
    adminUserRecord = await getAuth().createUser({
      email: adminEmail,
      password: tempPassword,
      displayName: `${adminName} ${adminLastname}`.trim() || adminEmail,
    });
  } catch (e) {
    if (e.code === "auth/email-already-exists") {
      adminUserRecord = await getAuth().getUserByEmail(adminEmail);
    } else {
      throw new HttpsError("internal", `Error creando admin: ${e.message}`);
    }
  }

  const now = FieldValue.serverTimestamp();
  const trialEndsAt = new Date();
  trialEndsAt.setDate(trialEndsAt.getDate() + trialDays);

  const associationData = {
    code: normalizedCode,
    name,
    city,
    phone: phone || null,
    email: adminEmail,
    status: "trial",
    pricingTierId,
    trialEndsAt,
    paidUntil: null,
    maxDrivers: tier.maxDrivers,
    maxOperators: tier.maxOperators,
    maxChannels: tier.maxChannels,
    ownerUid: adminUserRecord.uid,
    theme: {
      primaryColor: theme?.primaryColor || "#1565C0",
      secondaryColor: theme?.secondaryColor || "#FFC107",
      accentColor: theme?.accentColor || "#0D47A1",
      logoUrl: theme?.logoUrl || null,
    },
    createdAt: now,
    updatedAt: now,
  };

  // Transacción: crear asociación + user del admin
  await db.runTransaction(async (tx) => {
    tx.set(aidRef, associationData);

    tx.set(db.collection("users").doc(adminUserRecord.uid), {
      associationId: slug,
      name: adminName,
      lastname: adminLastname,
      cedula: "",
      email: adminEmail,
      phone: phone || "",
      role: "admin",
      status: "active",
      isActive: true,
      createdAt: now,
      updatedAt: now,
    });
  });

  return {
    associationId: slug,
    code: normalizedCode,
    adminUid: adminUserRecord.uid,
    adminEmail,
    tempPassword: adminPassword ? null : tempPassword,
  };
});

// ───────────────────────────────────────────────────────────────────
//  migrateToMultitenant — script ONE-TIME que etiqueta todos los
//  documentos existentes con associationId="jipijapa".
//  Solo super-admin. Es idempotente.
// ───────────────────────────────────────────────────────────────────

const COLLECTIONS_TO_TAG = [
  "users",
  "drivers",
  "vehicles",
  "trips",
  "payments",
  "expenses",
  "channels",
  "messages",
  "chat_rooms",
  "emergencies",
  "competitor_trips",
  "taxi_stands",
  "incentives",
];

exports.migrateToMultitenant = onCall({ timeoutSeconds: 540 }, async (request) => {
  requireSuperAdmin(request);

  const { associationId = "jipijapa", dryRun = false } = request.data || {};

  // Verificar que la asociación destino existe
  const aidRef = db.collection("associations").doc(associationId);
  const aidSnap = await aidRef.get();
  if (!aidSnap.exists) {
    throw new HttpsError(
      "not-found",
      `La asociación ${associationId} no existe. Créala antes con createAssociation o seedDefaults.`
    );
  }

  const stats = {};

  for (const col of COLLECTIONS_TO_TAG) {
    const snap = await db.collection(col).get();
    let untagged = 0;
    let batch = db.batch();
    let batchSize = 0;

    for (const doc of snap.docs) {
      const data = doc.data();
      if (data.associationId) continue; // ya etiquetado
      untagged++;
      if (!dryRun) {
        batch.update(doc.ref, { associationId });
        batchSize++;
        if (batchSize >= 400) {
          await batch.commit();
          batch = db.batch();
          batchSize = 0;
        }
      }
    }

    if (!dryRun && batchSize > 0) {
      await batch.commit();
    }

    stats[col] = { total: snap.size, tagged: untagged };
  }

  return { ok: true, dryRun, associationId, stats };
});

// ───────────────────────────────────────────────────────────────────
//  seedDefaults — crea pricingTiers default y la asociación
//  inicial "jipijapa". Solo super-admin. Idempotente.
// ───────────────────────────────────────────────────────────────────

exports.seedDefaults = onCall({}, async (request) => {
  const auth = requireSuperAdmin(request);
  const now = FieldValue.serverTimestamp();

  // 1) Pricing tiers default
  const tiers = [
    {
      id: "trial",
      name: "Prueba gratuita",
      description: "30 días gratis para evaluar el servicio.",
      monthlyPriceUsd: 0,
      yearlyPriceUsd: 0,
      maxDrivers: 5,
      maxOperators: 1,
      maxChannels: 1,
      maxAgoraMinutesPerMonth: 5000,
      isPublic: false,
      sortOrder: 0,
    },
    {
      id: "basic",
      name: "Básico",
      description: "Para asociaciones pequeñas, hasta 30 conductores.",
      monthlyPriceUsd: 49,
      yearlyPriceUsd: 490,
      maxDrivers: 30,
      maxOperators: 1,
      maxChannels: 3,
      maxAgoraMinutesPerMonth: 50000,
      isPublic: true,
      sortOrder: 1,
    },
    {
      id: "pro",
      name: "Profesional",
      description: "Para asociaciones medianas, hasta 100 conductores.",
      monthlyPriceUsd: 129,
      yearlyPriceUsd: 1290,
      maxDrivers: 100,
      maxOperators: 3,
      maxChannels: 10,
      maxAgoraMinutesPerMonth: 200000,
      isPublic: true,
      sortOrder: 2,
    },
    {
      id: "enterprise",
      name: "Empresarial",
      description:
        "Sin límites de conductores ni canales. Soporte prioritario.",
      monthlyPriceUsd: 249,
      yearlyPriceUsd: 2490,
      maxDrivers: 99999,
      maxOperators: 99,
      maxChannels: 99,
      maxAgoraMinutesPerMonth: null,
      isPublic: true,
      sortOrder: 3,
    },
  ];

  const batch = db.batch();
  for (const t of tiers) {
    const ref = db.collection("pricingTiers").doc(t.id);
    const snap = await ref.get();
    const payload = { ...t, updatedAt: now };
    delete payload.id;
    if (!snap.exists) payload.createdAt = now;
    batch.set(ref, payload, { merge: true });
  }
  await batch.commit();

  // 2) Asociación "jipijapa" (la actual)
  const jipiRef = db.collection("associations").doc("jipijapa");
  const jipiSnap = await jipiRef.get();
  if (!jipiSnap.exists) {
    await jipiRef.set({
      code: "JIPI",
      name: "Asociación de Taxis Jipijapa",
      city: "Quito",
      phone: null,
      email: null,
      status: "active",
      pricingTierId: "basic",
      trialEndsAt: null,
      paidUntil: null,
      maxDrivers: 30,
      maxOperators: 1,
      maxChannels: 3,
      ownerUid: auth.uid,
      theme: {
        primaryColor: "#1565C0",
        secondaryColor: "#FFC107",
        accentColor: "#0D47A1",
        logoUrl: null,
      },
      createdAt: now,
      updatedAt: now,
    });
  }

  return { ok: true, tiersSeeded: tiers.length, jipijapaCreated: !jipiSnap.exists };
});

// ───────────────────────────────────────────────────────────────────
//  purgeExpiredProofs — cron diario que borra los blobs de Cloud
//  Storage cuyos comprobantes pasaron `proofRetentionDays` días.
//  El doc Firestore queda permanente (auditoría); solo se purga el
//  blob físico y se setea `proof.photoExpired = true`.
//
//  Ejecución: cada día a las 02:00 hora Ecuador.
//  Memoria: 512MiB (procesa hasta 500 docs por corrida).
// ───────────────────────────────────────────────────────────────────

exports.purgeExpiredProofs = onSchedule(
  {
    schedule: "every day 02:00",
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async (event) => {
    const now = new Date();
    const bucket = getStorage().bucket();

    // Hasta 500 docs por corrida. Si hay más caducados, mañana
    // se procesan los siguientes (cada día se reduce el backlog).
    const snap = await db
      .collection("payments")
      .limit(500)
      .get();

    let scanned = 0;
    let candidates = 0;
    let blobsDeleted = 0;
    let blobsNotFound = 0;
    let blobsFailed = 0;

    for (const doc of snap.docs) {
      scanned++;
      const data = doc.data();
      const proof = data.proof || {};

      // Skip si ya purgado, sin photoUrl, o sin fecha de expiración
      if (proof.photoExpired === true) continue;
      if (!proof.photoUrl) continue;
      if (!proof.photoExpiresAt) continue;

      // Resolver Date desde Firestore Timestamp
      const expiresAt =
        proof.photoExpiresAt.toDate
          ? proof.photoExpiresAt.toDate()
          : new Date(proof.photoExpiresAt);

      if (expiresAt > now) continue; // aún no expira

      candidates++;
      const path = _parseStoragePath(proof.photoUrl);

      if (path) {
        try {
          await bucket.file(path).delete();
          blobsDeleted++;
        } catch (e) {
          // 404 = ya no existe el blob, no es error real
          const code = e && e.code;
          if (code === 404 || (e && /No such object/i.test(e.message || ""))) {
            blobsNotFound++;
          } else {
            blobsFailed++;
            console.warn(
              `purgeExpiredProofs: falló borrando ${path}: ${e.message || e}`
            );
          }
        }
      } else {
        blobsFailed++;
        console.warn(
          `purgeExpiredProofs: no pude parsear path de ${proof.photoUrl}`
        );
      }

      // Marcar el doc como purgado, conservando metadata histórica
      try {
        await doc.ref.update({
          "proof.photoExpired": true,
          "proof.photoUrl": null,
          updatedAt: FieldValue.serverTimestamp(),
        });
      } catch (e) {
        console.warn(
          `purgeExpiredProofs: falló update doc ${doc.id}: ${e.message || e}`
        );
      }
    }

    console.log(
      `purgeExpiredProofs: scanned=${scanned} candidates=${candidates} ` +
        `deleted=${blobsDeleted} notFound=${blobsNotFound} failed=${blobsFailed}`
    );
  }
);

/**
 * Extrae el path del bucket desde un download URL de Firebase Storage.
 * Formato del URL:
 *   https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<path>?alt=media&token=...
 * Retorna `<path>` ya URL-decoded, o null si no se puede parsear.
 */
function _parseStoragePath(url) {
  if (!url || typeof url !== "string") return null;
  const m = url.match(/\/o\/([^?]+)/);
  if (!m) return null;
  try {
    return decodeURIComponent(m[1]);
  } catch (_) {
    return null;
  }
}

// ───────────────────────────────────────────────────────────────────
//  purgeExpiredProofsNow — versión callable de la misma lógica para
//  que el super-admin la ejecute manualmente desde el panel SaaS
//  (útil para limpiar de inmediato sin esperar al cron).
// ───────────────────────────────────────────────────────────────────

exports.purgeExpiredProofsNow = onCall({}, async (request) => {
  requireSuperAdmin(request);

  const now = new Date();
  const bucket = getStorage().bucket();

  const snap = await db.collection("payments").limit(500).get();

  let scanned = 0;
  let candidates = 0;
  let blobsDeleted = 0;
  let blobsNotFound = 0;
  let blobsFailed = 0;

  for (const doc of snap.docs) {
    scanned++;
    const data = doc.data();
    const proof = data.proof || {};

    if (proof.photoExpired === true) continue;
    if (!proof.photoUrl) continue;
    if (!proof.photoExpiresAt) continue;

    const expiresAt = proof.photoExpiresAt.toDate
      ? proof.photoExpiresAt.toDate()
      : new Date(proof.photoExpiresAt);
    if (expiresAt > now) continue;

    candidates++;
    const path = _parseStoragePath(proof.photoUrl);

    if (path) {
      try {
        await bucket.file(path).delete();
        blobsDeleted++;
      } catch (e) {
        const code = e && e.code;
        if (code === 404 || (e && /No such object/i.test(e.message || ""))) {
          blobsNotFound++;
        } else {
          blobsFailed++;
        }
      }
    } else {
      blobsFailed++;
    }

    await doc.ref.update({
      "proof.photoExpired": true,
      "proof.photoUrl": null,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  return {
    ok: true,
    scanned,
    candidates,
    blobsDeleted,
    blobsNotFound,
    blobsFailed,
  };
});

// ──────────────────────────────────────────────────────────────────
//  enforcePayments — cron diario 00:00 America/Guayaquil
//  Pase A: suspende asociaciones con paidUntil/trialEndsAt vencido.
//  Pase B: bloquea conductores en mora (Task 7).
//  Pase C: reactiva los que ya tienen pago al día (Task 8).
// ──────────────────────────────────────────────────────────────────

exports.enforcePayments = onSchedule(
  {
    schedule: "every day 00:00",
    timeZone: "America/Guayaquil",
    memory: "512MiB",
    timeoutSeconds: 540,
  },
  async (event) => {
    const now = Timestamp.now();
    console.log("[enforcePayments] start", now.toDate().toISOString());

    // ─── Pase A: asociaciones vencidas ───
    const assocSnap = await db
      .collection("associations")
      .where("status", "in", ["active", "trial"])
      .get();

    let suspendedCount = 0;
    for (const doc of assocSnap.docs) {
      const a = doc.data();
      const isTrial = a.status === "trial";
      const expiry = isTrial ? a.trialEndsAt : a.paidUntil;
      if (!expiry) continue;
      const expiryDate = expiry.toDate ? expiry.toDate() : new Date(expiry);
      if (expiryDate.getTime() > now.toMillis()) continue;

      await doc.ref.update({
        status: "suspended",
        suspendedAt: now,
        suspendedReason: isTrial ? "expired_trial" : "expired_paid_until",
        updatedAt: now,
      });
      suspendedCount++;
      console.log(
        `[enforcePayments] suspended assoc ${doc.id} (${a.name || ""})`
      );

      // FCM a TODOS los admins activos de la asoc (puede haber 2+ via addCoAdmin)
      const adminsSnap = await db
        .collection("users")
        .where("associationId", "==", doc.id)
        .where("role", "==", "admin")
        .where("status", "==", "active")
        .get();
      await Promise.all(
        adminsSnap.docs.map((aDoc) =>
          _sendFcmToUid(aDoc.id, {
            title: "Cooperativa suspendida",
            body: `Tu cooperativa ${a.name || ""} fue suspendida por mora. Paga la membresía para reactivarla.`,
          }).catch((e) => console.error("FCM error admin", e))
        )
      );
    }

    console.log(`[enforcePayments] A=${suspendedCount}`);

    // ─── Pase B: conductores en mora ───
    const { computeNextDueDate } = require("./lib/dueDate");

    const activeAssocs = await db.collection("associations")
      .where("status", "==", "active")
      .get();

    let blockedCount = 0;
    for (const aDoc of activeAssocs.docs) {
      const cfg = aDoc.data().billingConfig;
      if (!cfg || !(cfg.amount > 0)) continue;

      const usersSnap = await db.collection("users")
        .where("associationId", "==", aDoc.id)
        .where("status", "==", "active")
        .get();

      for (const uDoc of usersSnap.docs) {
        const u = uDoc.data();
        if (!["conductor", "admin"].includes(u.role)) continue;
        if (!u.approvedAt) continue;

        const last = await _lastValidatedPayment(uDoc.id, aDoc.id);
        const nextDue = computeNextDueDate(
          { approvedAt: u.approvedAt.toDate ? u.approvedAt.toDate() : u.approvedAt },
          cfg, last,
        );
        if (nextDue.getTime() > now.toMillis()) continue;
        if (await _hasActivePermit(uDoc.id, nextDue)) continue;

        await uDoc.ref.update({
          status: "paymentBlocked",
          blockedAt: now,
          blockReason: "cuota_vencida",
          updatedAt: now,
        });
        blockedCount++;
        console.log(`[enforcePayments] blocked user ${uDoc.id}`);

        await _sendFcmToUid(uDoc.id, {
          title: "Tu cuenta fue bloqueada",
          body: "Sube tu comprobante de pago para reactivarte.",
        }).catch(() => {});
      }
    }

    console.log(`[enforcePayments] B=${blockedCount}`);

    // ─── Pase C: re-activar conductores con pago al día ───
    const blockedSnap = await db.collection("users")
      .where("status", "==", "paymentBlocked")
      .where("blockReason", "==", "cuota_vencida")
      .get();

    let reactivatedCount = 0;
    for (const uDoc of blockedSnap.docs) {
      const u = uDoc.data();
      const aDoc = await db.collection("associations").doc(u.associationId).get();
      if (!aDoc.exists) continue;
      const cfg = aDoc.data().billingConfig;
      if (!cfg) continue;

      const last = await _lastValidatedPayment(uDoc.id, u.associationId);
      if (!last) continue;
      const nextDue = computeNextDueDate(
        { approvedAt: u.approvedAt.toDate() },
        cfg, last,
      );
      if (nextDue.getTime() <= now.toMillis()) continue;

      await uDoc.ref.update({
        status: "active",
        blockedAt: FieldValue.delete(),
        blockReason: FieldValue.delete(),
        updatedAt: now,
      });
      reactivatedCount++;
      console.log(`[enforcePayments] reactivated user ${uDoc.id}`);

      await _sendFcmToUid(uDoc.id, {
        title: "Cuenta reactivada",
        body: "Tu cuenta fue reactivada. Bienvenido de vuelta.",
      }).catch(() => {});
    }

    console.log(`[enforcePayments] C=${reactivatedCount}`);
    return { suspended: suspendedCount, blocked: blockedCount, reactivated: reactivatedCount };
  }
);

/// Helper interno para enviar FCM a un uid usando el fcmToken guardado.
async function _sendFcmToUid(uid, payload) {
  const u = await db.collection("users").doc(uid).get();
  const token = u.data()?.fcmToken;
  if (!token) return;
  const { getMessaging } = require("firebase-admin/messaging");
  await getMessaging().send({
    token,
    notification: { title: payload.title, body: payload.body },
  });
}

/// Último pago validado y NO anulado del conductor.
async function _lastValidatedPayment(uid, associationId) {
  const snap = await db.collection("payments")
    .where("driverId", "==", uid)
    .where("associationId", "==", associationId)
    .where("status", "==", "validated")
    .orderBy("validatedAt", "desc")
    .limit(10)
    .get();
  for (const d of snap.docs) {
    if (!d.data().voidedAt) return d.data();
  }
  return null;
}

/// True si el conductor tiene un permiso activo cubriendo la fecha dada.
async function _hasActivePermit(uid, dateCovered) {
  const snap = await db.collection("permissions")
    .where("driverId", "==", uid)
    .where("status", "==", "active")
    .limit(5)
    .get();
  for (const d of snap.docs) {
    const p = d.data();
    const start = p.startDate?.toDate?.();
    const end = p.expectedEndDate?.toDate?.();
    if (!start || !end) continue;
    if (dateCovered >= start && dateCovered <= end) return true;
  }
  return false;
}

// ───────────────────────────────────────────────────────────────────
//  checkSubscriptions — cron diario 00:05 ECU.
//  Para cada asociación:
//   - Calcula la fecha de expiración (trialEndsAt si trial, paidUntil si paid).
//   - Si ya expiró pero está dentro del período de gracia (default 3 días):
//      - association.status = "expired" (si no estaba ya).
//      - conductores activos pasan a UserStatus.paymentPending (banner).
//   - Si pasó el período de gracia:
//      - conductores en paymentPending pasan a paymentBlocked (modo solo pago).
//   - Si la asociación volvió a estar al día (paidUntil >= now):
//      - association.status = "active".
//      - conductores en paymentPending|paymentBlocked vuelven a active.
//
//  Idempotente: corre cada día y solo aplica diffs.
//  Trigger manual: usar `checkSubscriptionsNow` (callable, super-admin).
// ───────────────────────────────────────────────────────────────────

const SUBSCRIPTION_GRACE_DAYS = 3;

async function _runSubscriptionCheck() {
  const now = new Date();
  const graceCutoff = new Date(
    now.getTime() - SUBSCRIPTION_GRACE_DAYS * 24 * 60 * 60 * 1000
  );

  const associationsSnap = await db.collection("associations").get();
  const summary = {
    associationsScanned: 0,
    associationsExpired: 0,
    associationsReactivated: 0,
    driversWarned: 0,
    driversBlocked: 0,
    driversReactivated: 0,
  };

  for (const aDoc of associationsSnap.docs) {
    summary.associationsScanned++;
    const a = aDoc.data();

    // Determinar fecha de expiración efectiva.
    const trialEndsAt = a.trialEndsAt?.toDate?.() || a.trialEndsAt || null;
    const paidUntil = a.paidUntil?.toDate?.() || a.paidUntil || null;
    const expiresAt = paidUntil || trialEndsAt;

    if (!expiresAt) {
      // Asociación sin fecha de expiración → no la tocamos (se asume legacy).
      continue;
    }

    const isExpired = expiresAt < now;
    const isPastGrace = expiresAt < graceCutoff;
    const newStatus = isExpired ? "expired" : "active";

    // Actualizar el doc de la asociación si hace falta.
    if (a.status !== newStatus) {
      await aDoc.ref.update({
        status: newStatus,
        updatedAt: FieldValue.serverTimestamp(),
      });
      if (newStatus === "expired") summary.associationsExpired++;
      else summary.associationsReactivated++;
    }

    // Recorrer conductores Y admins de esta asociación.
    // Cuando la suscripción caduca, TODOS (admins y socios) deben quedar
    // bloqueados con el mismo flujo (paymentPending → paymentBlocked).
    // El mensaje al admin difiere en la app: dice "contacta a tu proveedor
    // para renovar la suscripción" en vez de "sube comprobante".
    // Las operadoras también se bloquean — sin admin/operadora la asociación
    // no opera.
    const usersSnap = await db
      .collection("users")
      .where("associationId", "==", aDoc.id)
      .where("role", "in", ["conductor", "admin", "operadora"])
      .get();

    for (const uDoc of usersSnap.docs) {
      const u = uDoc.data();
      const currentStatus = u.status || "active";

      // No tocar usuarios bloqueados manualmente por admin.
      if (currentStatus === "disabledByAdmin") continue;
      // No tocar usuarios pendientes de aprobación o rechazados.
      if (currentStatus === "pendingApproval" || currentStatus === "rejected") {
        continue;
      }

      let nextStatus = currentStatus;
      if (!isExpired) {
        // Asociación al día → desbloquear.
        if (
          currentStatus === "paymentPending" ||
          currentStatus === "paymentBlocked"
        ) {
          nextStatus = "active";
          summary.driversReactivated++;
        }
      } else if (isPastGrace) {
        // Pasado el período de gracia → bloquear.
        if (currentStatus !== "paymentBlocked") {
          nextStatus = "paymentBlocked";
          summary.driversBlocked++;
        }
      } else {
        // Dentro del período de gracia → warning.
        if (currentStatus === "active") {
          nextStatus = "paymentPending";
          summary.driversWarned++;
        }
      }

      if (nextStatus !== currentStatus) {
        await uDoc.ref.update({
          status: nextStatus,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    }
  }

  return summary;
}

// ───────────────────────────────────────────────────────────────────
//  addCoAdmin — sube a un conductor a admin SIN degradar al admin actual.
//  Permite tener múltiples admins en la misma asociación.
//  Solo el admin actual o super-admin pueden invocar.
// ───────────────────────────────────────────────────────────────────

exports.addCoAdmin = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const callerEmail = auth.token.email || "";
  const isSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);

  const { targetUid } = request.data || {};
  if (!targetUid) {
    throw new HttpsError("invalid-argument", "targetUid es obligatorio.");
  }

  const targetSnap = await db.collection("users").doc(targetUid).get();
  if (!targetSnap.exists) {
    throw new HttpsError("not-found", "Usuario destino no existe.");
  }
  const target = targetSnap.data();

  // Solo el admin actual de esa asociación o super-admin pueden promover.
  if (!isSuper) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    if (!callerSnap.exists) {
      throw new HttpsError("permission-denied", "Caller no existe.");
    }
    const caller = callerSnap.data();
    if (
      caller.role !== "admin" ||
      caller.associationId !== target.associationId ||
      (caller.status || "active") !== "active"
    ) {
      throw new HttpsError(
        "permission-denied",
        "Solo el admin activo de esa asociación o super-admin puede agregar co-admins.",
      );
    }
  }

  if (target.role === "admin") {
    return { ok: true, alreadyAdmin: true };
  }

  await targetSnap.ref.update({
    role: "admin",
    updatedAt: FieldValue.serverTimestamp(),
  });

  return { ok: true, uid: targetUid, newRole: "admin" };
});

exports.checkSubscriptions = onSchedule(
  {
    schedule: "5 0 * * *", // 00:05 todos los días
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "256MiB",
    retryCount: 2,
  },
  async () => {
    const summary = await _runSubscriptionCheck();
    console.log("checkSubscriptions:", JSON.stringify(summary));
    return summary;
  }
);

exports.checkSubscriptionsNow = onCall({}, async (request) => {
  requireSuperAdmin(request);
  const summary = await _runSubscriptionCheck();
  return { ok: true, ...summary };
});

// ───────────────────────────────────────────────────────────────────
//  fetchQuitoEvents — cron diario 06:00 ECU.
//  Pregunta a Gemini qué eventos públicos masivos hay hoy en Quito y los
//  guarda en eventsQuito/{yyyy-mm-dd}. La app los muestra para que los
//  conductores anticipen aglomeraciones (conciertos, partidos, marchas).
//
//  Requiere secret GEMINI_API_KEY: `firebase functions:secrets:set GEMINI_API_KEY`
//  Si la key no está configurada, la función hace log y termina sin error.
// ───────────────────────────────────────────────────────────────────

async function _fetchEventsFromGemini(apiKey, dateLabel) {
  const prompt = `Eres un asistente para conductores de taxi en Quito, Ecuador.
Usa búsqueda en tiempo real para encontrar TODOS los eventos públicos
previstos para HOY (${dateLabel}) en Quito y el Distrito Metropolitano que
puedan generar aglomeración de gente, demanda de taxis o tráfico.

Cubre AMPLIAMENTE estas categorías y venues (la lista NO es exhaustiva, si
encuentras otros eventos relevantes inclúyelos):

- Deportes: Estadio Olímpico Atahualpa, Estadio Casa Blanca (LDU), Coliseo
  General Rumiñahui, Coliseo Julio César Hidalgo, Plaza de Toros Quito,
  partidos LigaPro, copas internacionales, encuentros de selección.
- Carreras y ciclismo: 5K/10K, media maratón, maratón, Ruta de las Iglesias,
  Quito 11K, ciclopaseo dominical (cierre de la 6 de Diciembre/Amazonas),
  triatlones, eventos UCI.
- Conciertos y espectáculos: Coliseo Rumiñahui, Ágora Casa de la Cultura,
  Teatro Nacional CCE, Teatro Sucre, Teatro Bolívar, Teatro México, Centro
  de Convenciones Quorum (Cumbayá), Plaza Foch, Itchimbía, Bicentenario,
  Quitumbe, La Carolina, Parque Metropolitano, La Concha Acústica.
- Ferias, festivales y mercados: Quito Fest, Fiestas de Quito (diciembre),
  Carnaval, Inti Raymi, festivales gastronómicos, ferias del libro/tecnología/
  vehículos, Expoflor, ferias en Centro de Exposiciones Quito (CEMEXPO).
- Eventos cívico-religiosos: procesiones (Jesús del Gran Poder, Semana Santa),
  feriados nacionales/locales, desfiles cívicos, posesiones presidenciales.
- Marchas, paros y manifestaciones: marchas sindicales, indígenas (CONAIE),
  estudiantiles, gremiales; bloqueos de vías. Revisa redes y prensa local.
- Universitarios y educativos: graduaciones masivas (PUCE, UCE, USFQ, EPN,
  Politécnica), inicios/fines de ciclo, congresos académicos.
- Centros comerciales con eventos especiales: Quicentro Norte/Sur, CCI,
  El Recreo, Condado, San Luis, Scala (lanzamientos, ferias, conciertos).
- Iglesia/turismo masivo: Mitad del Mundo, TelefériQo, Panecillo en feriados.
- Otros: convenciones internacionales, cumbres, Expo, ferias en Plataforma
  Gubernamental, eventos del Municipio, La Mariscal nocturna en fines de
  semana de feriado.

Para cada evento devuelve:
- name: nombre del evento
- venue: lugar exacto (no genérico)
- startTime: ISO8601 con offset -05:00 (Ecuador)
- endTime: ISO8601 si se conoce, null si no
- type: "concierto" | "deporte" | "teatro" | "marcha" | "feria" |
  "religioso" | "deportivo_calle" | "ciclopaseo" | "feriado" |
  "academico" | "convencion" | "otro"
- expectedAttendance: "baja" (<500) | "media" (500-3000) | "alta"
  (3000-15000) | "muy_alta" (>15000)
- approxLocation: { lat, lng } coordenadas del venue
- affectedZones: array de zonas con tráfico afectado, p. ej.
  ["La Carolina","Iñaquito","Norte","Centro Histórico","Cumbayá","Sur",
   "Valle de los Chillos","Quitumbe","Calderón","Pomasqui","Mitad del Mundo"]
- trafficPeakHours: array de strings "HH:MM" con horas pico estimadas de
  llegada/salida (ej. ["18:00","23:30"])
- taxiDemand: "baja" | "media" | "alta" — qué tan probable es que los
  asistentes pidan taxi al salir
- source: URL de la fuente donde verificaste el evento (importante)

Responde SOLO con JSON válido en este formato exacto, sin markdown ni
explicación:
{"events":[ ... ]}

Reglas:
- NO inventes datos. Si no estás seguro de un campo, usa null.
- Si un evento es recurrente (ciclopaseo dominical, ferias semanales),
  inclúyelo solo si HOY corresponde.
- Prefiere eventos confirmados con fuente verificable.
- Si no encuentras NINGÚN evento confirmado, devuelve {"events":[]}.
- Devuelve hasta 25 eventos máximo, priorizados por taxiDemand alta.`;

  // Body con Google Search grounding: el modelo busca en tiempo real
  // eventos reales para la fecha actual. responseMimeType es incompatible
  // con tools, así que parseamos el texto crudo con regex.
  const bodyGrounded = {
    contents: [{ parts: [{ text: prompt }] }],
    tools: [{ google_search: {} }],
    generationConfig: { temperature: 0.2 },
  };
  // Body sin grounding como fallback si la búsqueda no está disponible
  // o el modelo no la soporta.
  const bodyPlain = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: {
      temperature: 0.2,
      responseMimeType: "application/json",
    },
  };

  // Extrae el JSON {"events":[...]} de un texto que puede venir envuelto
  // en markdown, prosa o citas de grounding.
  const parseEvents = (text) => {
    if (!text) return [];
    // Intento 1: parsear todo como JSON puro.
    try {
      const p = JSON.parse(text);
      if (Array.isArray(p.events)) return p.events;
      if (Array.isArray(p)) return p;
    } catch (_) {
      // sigue
    }
    // Intento 2: extraer el primer bloque {...} que contenga "events".
    const m = text.match(/\{[\s\S]*?"events"[\s\S]*?\}\s*\}?/);
    if (m) {
      try {
        const p = JSON.parse(m[0]);
        if (Array.isArray(p.events)) return p.events;
      } catch (_) {
        // sigue
      }
    }
    // Intento 3: extraer un array [...] si el modelo devolvió solo eso.
    const arr = text.match(/\[[\s\S]*\]/);
    if (arr) {
      try {
        const p = JSON.parse(arr[0]);
        if (Array.isArray(p)) return p;
      } catch (_) {
        // sigue
      }
    }
    return [];
  };

  // Lista de modelos a probar en orden. Si gemini-2.5-flash está
  // saturado (503), caemos a 1.5-flash que suele tener menos demanda.
  const models = ["gemini-2.5-flash", "gemini-1.5-flash"];
  // Cada modelo se intenta primero con grounding, luego sin grounding.
  const variants = [
    { body: bodyGrounded, label: "grounded" },
    { body: bodyPlain, label: "plain" },
  ];

  let lastErr;
  for (const model of models) {
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(apiKey)}`;
    for (const variant of variants) {
      // Retry interno con back-off exponencial para 429/503/504.
      for (let attempt = 1; attempt <= 3; attempt++) {
        try {
          const res = await fetch(url, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(variant.body),
          });
          if (res.ok) {
            const data = await res.json();
            const text =
              data?.candidates?.[0]?.content?.parts?.[0]?.text || "";
            const events = parseEvents(text);
            console.log(
              `fetchQuitoEvents: ${model}/${variant.label} → ${events.length} eventos`,
            );
            return events;
          }
          const status = res.status;
          const text = await res.text();
          lastErr = new Error(`Gemini API ${status}: ${text.slice(0, 200)}`);
          // 400 con grounding = el modelo no soporta tools → siguiente variante.
          if (status === 400 && variant.label === "grounded") break;
          // 429/503/504 son transitorios → retry. 4xx (no 429) → no retry.
          if (status !== 429 && status !== 503 && status !== 504) break;
          // Back-off: 2s, 4s, 8s.
          await new Promise((r) =>
            setTimeout(r, 2000 * Math.pow(2, attempt - 1)),
          );
        } catch (e) {
          lastErr = e;
          if (attempt < 3) {
            await new Promise((r) =>
              setTimeout(r, 2000 * Math.pow(2, attempt - 1)),
            );
          }
        }
      }
      console.warn(
        `fetchQuitoEvents: ${model}/${variant.label} falló, probando siguiente…`,
      );
    }
  }
  throw lastErr || new Error("Gemini: todos los modelos fallaron");
}

async function _runFetchQuitoEvents(apiKey) {
  const now = new Date();
  const dateKey = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
  const dateLabel = now.toLocaleDateString("es-EC", {
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "America/Guayaquil",
  });
  // expireAt: 36 h después del cron de hoy → Firestore borra el doc
  // automáticamente (TTL configurado en eventsQuito.expireAt). Margen
  // de 12 h por encima de 24 h para que el doc esté visible toda la
  // jornada de hoy y madrugada de mañana antes de desaparecer.
  const expireAt = Timestamp.fromMillis(now.getTime() + 36 * 60 * 60 * 1000);

  if (!apiKey) {
    console.warn("fetchQuitoEvents: GEMINI_API_KEY no configurada, skip.");
    return { ok: false, reason: "no-api-key", dateKey };
  }

  let events = [];
  try {
    events = await _fetchEventsFromGemini(apiKey, dateLabel);
  } catch (e) {
    console.error("fetchQuitoEvents: error Gemini:", e.message);
    // Guardar igual el doc para que el cliente sepa que ya se intentó.
    await db.collection("eventsQuito").doc(dateKey).set(
      {
        date: dateKey,
        events: [],
        error: e.message,
        updatedAt: FieldValue.serverTimestamp(),
        expireAt,
      },
      { merge: true }
    );
    return { ok: false, reason: "gemini-error", dateKey, error: e.message };
  }

  await db.collection("eventsQuito").doc(dateKey).set({
    date: dateKey,
    events,
    error: null,
    updatedAt: FieldValue.serverTimestamp(),
    expireAt,
  });

  return { ok: true, dateKey, count: events.length };
}

exports.fetchQuitoEvents = onSchedule(
  {
    schedule: "0 6 * * *", // 06:00 todos los días
    timeZone: "America/Guayaquil",
    secrets: [GEMINI_API_KEY],
    timeoutSeconds: 120,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runFetchQuitoEvents(GEMINI_API_KEY.value());
    console.log("fetchQuitoEvents:", JSON.stringify(summary));
    return summary;
  }
);

exports.fetchQuitoEventsNow = onCall(
  { secrets: [GEMINI_API_KEY] },
  async (request) => {
    requireSuperAdmin(request);
    const summary = await _runFetchQuitoEvents(GEMINI_API_KEY.value());
    return summary;
  }
);

// ───────────────────────────────────────────────────────────────────
//  dispatchScheduledNotifications — cron cada 5 min.
//  Toma `notifications/{}` con scheduledAt <= now y status='scheduled' y
//  dispara FCM a los tokens de la audiencia. Marca status='dispatched'.
//
//  Schema esperado en notifications/{}:
//    { associationId, title, body, audience: 'all'|'drivers'|'operadoras',
//      scheduledAt: Timestamp|null, status: 'scheduled'|'dispatched'|'failed',
//      createdBy, createdAt }
// ───────────────────────────────────────────────────────────────────

async function _runDispatchScheduledNotifications() {
  const now = new Date();
  const snap = await db
    .collection("notifications")
    .where("status", "==", "scheduled")
    .where("scheduledAt", "<=", now)
    .limit(50)
    .get();

  let dispatched = 0;
  let failed = 0;

  for (const d of snap.docs) {
    const n = d.data();
    try {
      // Audiencia → query users del tenant filtrado por rol.
      let usersQuery = db
        .collection("users")
        .where("associationId", "==", n.associationId)
        .where("status", "==", "active");
      if (n.audience === "drivers") {
        usersQuery = usersQuery.where("role", "==", "conductor");
      } else if (n.audience === "operadoras") {
        usersQuery = usersQuery.where("role", "==", "operadora");
      }
      const usersSnap = await usersQuery.get();
      const tokens = [];
      for (const u of usersSnap.docs) {
        const fcm = u.data().fcmToken;
        if (typeof fcm === "string" && fcm.length > 0) tokens.push(fcm);
      }
      if (tokens.length > 0) {
        // Importar messaging on-demand para no romper deploys donde no se usa.
        const { getMessaging } = require("firebase-admin/messaging");
        await getMessaging().sendEachForMulticast({
          tokens,
          notification: { title: n.title || "Aviso", body: n.body || "" },
          data: { type: "admin_notification", notifId: d.id },
        });
      }
      // TTL 72h: si el creador no seteó expiresAt, lo derivamos aquí
      // como now + 72h. Después purgeExpiredNotifications borra el doc.
      const update = {
        status: "dispatched",
        dispatchedAt: FieldValue.serverTimestamp(),
        recipientsCount: tokens.length,
      };
      if (!n.expiresAt) {
        const exp = new Date();
        exp.setHours(exp.getHours() + 72);
        update.expiresAt = Timestamp.fromDate(exp);
      }
      await d.ref.update(update);
      dispatched++;
    } catch (e) {
      console.error("dispatch notif", d.id, e.message);
      await d.ref.update({
        status: "failed",
        error: e.message,
        updatedAt: FieldValue.serverTimestamp(),
      });
      failed++;
    }
  }
  return { ok: true, scanned: snap.size, dispatched, failed };
}

exports.dispatchScheduledNotifications = onSchedule(
  {
    schedule: "*/5 * * * *",
    timeZone: "America/Guayaquil",
    timeoutSeconds: 120,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runDispatchScheduledNotifications();
    console.log("dispatchScheduledNotifications:", JSON.stringify(summary));
    return summary;
  }
);

// ───────────────────────────────────────────────────────────────────
//  purgeExpiredNotifications — cron diario 02:30 ECU.
//  Borra docs de `notifications` con expiresAt <= now. TTL típico 72h.
//  (Los push de Android se borran solos del shade; este cron limpia el
//   historial guardado en Firestore.)
// ───────────────────────────────────────────────────────────────────

async function _runPurgeExpiredNotifications() {
  const now = Timestamp.now();
  let deleted = 0;
  let scanned = 0;
  // Lotes de 200 para no excederse del límite de batch (500).
  while (true) {
    const snap = await db
      .collection("notifications")
      .where("expiresAt", "<=", now)
      .limit(200)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    for (const d of snap.docs) {
      batch.delete(d.ref);
      scanned++;
    }
    await batch.commit();
    deleted += snap.size;
    if (snap.size < 200) break; // última tanda
  }
  return { ok: true, deleted, scanned };
}

exports.purgeExpiredNotifications = onSchedule(
  {
    schedule: "30 2 * * *",
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runPurgeExpiredNotifications();
    console.log("purgeExpiredNotifications:", JSON.stringify(summary));
    return summary;
  }
);

// ───────────────────────────────────────────────────────────────────
//  purgeOldChatMessages — cron cada hora.
//  Recorre chat_rooms/{}/messages/{} con expiresAt <= now y los borra.
//  Si el mensaje tiene imagePath, también elimina el blob en Storage
//  (chat_images/{roomId}/{msgId}.jpg).
//
//  Cumple el requerimiento de Byron: "todo se guarde por 24h en el celular
//  de cada usuario no en nube". Firestore actúa como transporte temporal y
//  esta función limpia automáticamente.
// ───────────────────────────────────────────────────────────────────

async function _runPurgeOldChatMessages() {
  const now = new Date();
  const roomsSnap = await db.collection("chat_rooms").get();
  let scanned = 0;
  let docsDeleted = 0;
  let blobsDeleted = 0;
  let blobsFailed = 0;
  const bucket = getStorage().bucket();

  for (const roomDoc of roomsSnap.docs) {
    const expiredSnap = await roomDoc.ref
      .collection("messages")
      .where("expiresAt", "<=", now)
      .limit(200)
      .get();
    scanned += expiredSnap.size;
    for (const m of expiredSnap.docs) {
      const data = m.data();
      const imagePath = data.imagePath;
      if (typeof imagePath === "string" && imagePath.length > 0) {
        try {
          await bucket.file(imagePath).delete();
          blobsDeleted++;
        } catch (e) {
          // 404 → ya no existía; otros errores los contamos como fallidos.
          if ((e && e.code) !== 404) blobsFailed++;
        }
      }
      await m.ref.delete();
      docsDeleted++;
    }
  }
  return {
    ok: true,
    scanned,
    docsDeleted,
    blobsDeleted,
    blobsFailed,
  };
}

exports.purgeOldChatMessages = onSchedule(
  {
    schedule: "0 * * * *", // cada hora en el minuto 0
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runPurgeOldChatMessages();
    console.log("purgeOldChatMessages:", JSON.stringify(summary));
    return summary;
  }
);

exports.purgeOldChatMessagesNow = onCall({}, async (request) => {
  requireSuperAdmin(request);
  return await _runPurgeOldChatMessages();
});

// ───────────────────────────────────────────────────────────────────
//  backfillAssociationId — migración one-shot.
//  Asigna `associationId = "jipijapa"` (o el slug que se pase) a todos
//  los docs legacy que no lo tengan, en las colecciones que las reglas
//  Firestore exigen multi-tenant: channels, messages, drivers, trips,
//  payments, expenses, taxi_stands, emergencies, competitor_trips.
//
//  Solo super-admin. Idempotente: si ya tiene associationId, lo skipea.
//
//  Uso desde la app o Functions shell:
//    backfillAssociationId({ associationId: 'jipijapa' })
// ───────────────────────────────────────────────────────────────────

// ───────────────────────────────────────────────────────────────────
//  checkDriverDues — cron diario 00:30 ECU.
//  Lógica de MEMBRESÍA DEL CONDUCTOR en su grupo (NO la suscripción
//  del SaaS — eso es checkSubscriptions).
//
//  Para cada asociación con billingConfig:
//   - Calcula el inicio del período actual (today - period).
//   - Para cada conductor activo:
//     - Busca `payments` con driverId==X, status==validated, concept==
//       billingConfig.defaultConcept, paymentDate >= periodStart.
//     - Si NO existe pago en el período actual:
//        - Si pasó el dueDate + graceDays (default 3) → paymentBlocked.
//        - Si está en gracia → paymentPending.
//     - Si existe → active (desbloquear si estaba bloqueado).
//
//  Idempotente. Solo toca conductores. NO toca admins/operadoras (su pago
//  es al SaaS, lo maneja checkSubscriptions).
// ───────────────────────────────────────────────────────────────────

const DRIVER_DUES_GRACE_DAYS = 3;

function _periodStartFor(billingConfig, now) {
  const every = Number(billingConfig?.period?.every) || 1;
  const unit = billingConfig?.period?.unit || "month";
  const start = new Date(now);
  switch (unit) {
    case "day":
      start.setDate(start.getDate() - every);
      break;
    case "week":
      start.setDate(start.getDate() - every * 7);
      break;
    case "year":
      start.setFullYear(start.getFullYear() - every);
      break;
    case "month":
    default:
      start.setMonth(start.getMonth() - every);
      break;
  }
  return start;
}

async function _runCheckDriverDues() {
  const now = new Date();
  const summary = {
    associationsScanned: 0,
    driversWarned: 0,
    driversBlocked: 0,
    driversReactivated: 0,
  };

  const associationsSnap = await db.collection("associations").get();
  for (const aDoc of associationsSnap.docs) {
    summary.associationsScanned++;
    const a = aDoc.data();
    const bc = a.billingConfig;
    if (!bc || !bc.amount || bc.amount <= 0) {
      continue; // sin cobro configurado, skip
    }

    const periodStart = _periodStartFor(bc, now);
    const concept = bc.defaultConcept || "cuota_mensual";

    // Conductores activos de la asociación.
    const driversSnap = await db
      .collection("users")
      .where("associationId", "==", aDoc.id)
      .where("role", "==", "conductor")
      .get();

    for (const uDoc of driversSnap.docs) {
      const u = uDoc.data();
      const status = u.status || "active";
      if (
        status === "disabledByAdmin" ||
        status === "pendingApproval" ||
        status === "rejected"
      ) {
        continue;
      }

      // Buscar pago validado en el período actual.
      const paySnap = await db
        .collection("payments")
        .where("driverId", "==", uDoc.id)
        .where("associationId", "==", aDoc.id)
        .where("status", "==", "validated")
        .where("concept", "==", concept)
        .where("paymentDate", ">=", periodStart)
        .limit(1)
        .get();
      const hasPaid = !paySnap.empty;

      let nextStatus = status;
      if (hasPaid) {
        if (status === "paymentPending" || status === "paymentBlocked") {
          nextStatus = "active";
          summary.driversReactivated++;
        }
      } else {
        // No pagó en el período. Determinar gracia.
        const graceCutoff = new Date(now);
        graceCutoff.setDate(graceCutoff.getDate() - DRIVER_DUES_GRACE_DAYS);
        // Asumimos que el dueDate del período actual es ahora-now relativo;
        // simplificado: si pasó la gracia desde el inicio del período → blocked.
        if (periodStart < graceCutoff) {
          if (status !== "paymentBlocked") {
            nextStatus = "paymentBlocked";
            summary.driversBlocked++;
          }
        } else {
          if (status === "active") {
            nextStatus = "paymentPending";
            summary.driversWarned++;
          }
        }
      }

      if (nextStatus !== status) {
        await uDoc.ref.update({
          status: nextStatus,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    }
  }

  return summary;
}

exports.checkDriverDues = onSchedule(
  {
    schedule: "30 0 * * *", // 00:30 todos los días
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "256MiB",
    retryCount: 2,
  },
  async () => {
    const summary = await _runCheckDriverDues();
    console.log("checkDriverDues:", JSON.stringify(summary));
    return summary;
  },
);

exports.checkDriverDuesNow = onCall({}, async (request) => {
  requireSuperAdmin(request);
  return await _runCheckDriverDues();
});

exports.backfillAssociationId = onCall(
  { timeoutSeconds: 540 },
  async (request) => {
    requireSuperAdmin(request);
    const aid = (request.data?.associationId || "jipijapa").toString();
    if (!aid) {
      throw new HttpsError(
        "invalid-argument",
        "associationId vacío",
      );
    }

    const COLLECTIONS = [
      "channels",
      "messages",
      "drivers",
      "trips",
      "payments",
      "expenses",
      "taxi_stands",
      "emergencies",
      "competitor_trips",
      "vehicles",
      "incentives",
    ];

    const summary = {};

    for (const coll of COLLECTIONS) {
      let updated = 0;
      let scanned = 0;
      const snap = await db.collection(coll).get();
      for (const d of snap.docs) {
        scanned++;
        const data = d.data();
        const current = data.associationId;
        if (typeof current === "string" && current.length > 0) {
          continue; // ya tiene, no tocar
        }
        await d.ref.update({
          associationId: aid,
          updatedAt: FieldValue.serverTimestamp(),
        });
        updated++;
      }
      summary[coll] = { scanned, updated };
    }

    console.log("backfillAssociationId:", JSON.stringify(summary));
    return { ok: true, associationId: aid, ...summary };
  },
);

// ───────────────────────────────────────────────────────────────────
//  sendPasswordResetEmail — envía correo de recuperación con SMTP propio
// ───────────────────────────────────────────────────────────────────
//
// Por qué no usamos directamente `auth.sendPasswordResetEmail` del Web
// SDK: el remitente por defecto `noreply@taxis-f0f51.firebaseapp.com`
// tiene reputación baja en Gmail y los correos terminan en spam (o no
// llegan). Esta función:
//
//   1. Genera el link de reset con Admin SDK (no envía nada).
//   2. Envía el correo nosotros mismos vía nodemailer + Gmail SMTP.
//
// Es **NO autenticada** (público) — igual que el endpoint nativo de
// Firebase, debe poder usarse sin estar logueado. La protección
// anti-enumeración: no revelamos si el email existe o no, siempre
// respondemos `{ ok: true }`.
//
// Setup de secrets (una sola vez):
//   firebase functions:secrets:set GMAIL_USER
//   firebase functions:secrets:set GMAIL_APP_PASSWORD
//
exports.sendPasswordResetEmail = onCall(
  {
    secrets: [GMAIL_USER, GMAIL_APP_PASSWORD],
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    const email = (request.data?.email || "").toString().trim().toLowerCase();
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      throw new HttpsError("invalid-argument", "Email inválido.");
    }

    // Rate-limit suave por email: si ya pidieron un reset hace menos de
    // 60s, devolvemos ok pero no enviamos otro correo.
    const rateRef = db
      .collection("password_reset_throttle")
      .doc(Buffer.from(email).toString("base64").replace(/=/g, ""));
    try {
      const snap = await rateRef.get();
      const last = snap.data()?.lastSentAt?.toMillis?.() ?? 0;
      if (Date.now() - last < 60_000) {
        console.log(`reset throttled for ${email}`);
        return { ok: true, throttled: true };
      }
    } catch (e) {
      // No bloqueamos por error de rate-limit
      console.warn("rate-limit check failed:", e?.message);
    }

    let link;
    try {
      link = await getAuth().generatePasswordResetLink(email, {
        url: "https://taxis-f0f51.firebaseapp.com/__/auth/action",
        handleCodeInApp: false,
      });
    } catch (e) {
      // Si el email no está registrado, NO revelamos eso al cliente
      // (anti-enumeración). Logueamos y respondemos ok normal.
      const code = e?.errorInfo?.code || e?.code || "";
      if (
        code === "auth/user-not-found" ||
        code === "auth/email-not-found"
      ) {
        console.log(`reset attempt for non-existing user: ${email}`);
        return { ok: true };
      }
      console.error("generatePasswordResetLink error:", e);
      throw new HttpsError("internal", "No pudimos generar el link.");
    }

    // Enviar el correo con nodemailer.
    const nodemailer = require("nodemailer");
    const transporter = nodemailer.createTransport({
      service: "gmail",
      auth: {
        user: GMAIL_USER.value(),
        pass: GMAIL_APP_PASSWORD.value(),
      },
    });

    const html = `
      <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 480px; margin: 0 auto; padding: 24px; background: #f7f7f7;">
        <div style="background: #fff; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
          <h1 style="color: #1976D2; margin: 0 0 16px; font-size: 22px;">🚖 Taxis App</h1>
          <h2 style="margin: 0 0 12px; font-size: 18px; color: #222;">Recuperar contraseña</h2>
          <p style="color: #444; line-height: 1.5; font-size: 15px;">
            Recibimos una solicitud para restablecer tu contraseña.
            Haz clic en el botón para fijar una nueva:
          </p>
          <div style="text-align: center; margin: 24px 0;">
            <a href="${link}" style="display: inline-block; background: #1976D2; color: #fff; text-decoration: none; padding: 12px 28px; border-radius: 8px; font-weight: 600; font-size: 15px;">Restablecer contraseña</a>
          </div>
          <p style="color: #777; font-size: 13px; line-height: 1.5;">
            Si tú no pediste esto, puedes ignorar este correo: tu cuenta sigue
            siendo segura. El enlace caduca en 1 hora.
          </p>
          <p style="color: #aaa; font-size: 12px; margin-top: 24px; word-break: break-all;">
            Si el botón no funciona, copia y pega este enlace en tu navegador:<br>
            ${link}
          </p>
        </div>
        <p style="text-align: center; color: #aaa; font-size: 11px; margin-top: 16px;">
          Taxis App · Sistema de gestión de cooperativas de taxi
        </p>
      </div>
    `;

    try {
      await transporter.sendMail({
        from: `"Taxis App" <${GMAIL_USER.value()}>`,
        to: email,
        subject: "Restablece tu contraseña - Taxis App",
        text:
          `Recibimos una solicitud para restablecer tu contraseña.\n\n` +
          `Abre este enlace para crear una nueva (válido 1h):\n${link}\n\n` +
          `Si no fuiste tú, ignora este correo.`,
        html,
      });
      await rateRef.set(
        { lastSentAt: FieldValue.serverTimestamp(), email },
        { merge: true },
      );
      console.log(`reset email sent to ${email}`);
      return { ok: true };
    } catch (e) {
      console.error("nodemailer sendMail error:", e?.message || e);
      throw new HttpsError(
        "internal",
        "No pudimos enviar el correo. Intenta de nuevo.",
      );
    }
  },
);


// ───────────────────────────────────────────────────────────────────
//  backfillPayments — rellena driverName + driverVehicleNumber en docs antiguos
// ───────────────────────────────────────────────────────────────────
//
// Antes la función reportPayment NO denormalizaba el nombre/unidad del
// conductor al doc del pago. La UI del admin hacía fallback al UID
// truncado ('Conductor: YWRERZrs…'). Esta función limpia esos docs:
// recorre los payments donde driverName == null, hace lookup a
// users/{driverId} y completa los campos.
//
// Es **callable** y solo el super-admin puede ejecutarla. Se llama una
// sola vez tras el deploy de los cambios de denormalización; después
// queda dormant.
//
// Uso desde el cliente (admin):
//   await FirebaseFunctions.instance
//     .httpsCallable('backfillPayments').call({});
//
// Devuelve { ok: true, scanned, updated, skipped }.
//
exports.backfillPayments = onCall(
  { region: 'us-central1', timeoutSeconds: 300 },
  async (request) => {
    requireSuperAdmin(request);

    let scanned = 0;
    let updated = 0;
    let skipped = 0;
    const userCache = new Map();

    // Procesamos en lotes de 200 con cursor — evita cargar toda la
    // colección a memoria si hay miles de pagos.
    const pageSize = 200;
    let lastDoc = null;

    while (true) {
      let q = db.collection('payments').orderBy('reportedAt').limit(pageSize);
      if (lastDoc) q = q.startAfter(lastDoc);
      const snap = await q.get();
      if (snap.empty) break;

      const batch = db.batch();
      let pendingWrites = 0;

      for (const doc of snap.docs) {
        scanned++;
        const data = doc.data();
        // Si ya tiene driverName, saltar.
        if (data.driverName && data.driverName.length > 0) {
          skipped++;
          continue;
        }
        const driverId = data.driverId;
        if (!driverId) {
          skipped++;
          continue;
        }
        let user = userCache.get(driverId);
        if (user === undefined) {
          const uSnap = await db.collection('users').doc(driverId).get();
          user = uSnap.exists ? uSnap.data() : null;
          userCache.set(driverId, user);
        }
        if (!user) {
          skipped++;
          continue;
        }
        const fullName = [user.name, user.lastname]
          .filter(Boolean).join(' ').trim();
        const update = {};
        if (fullName) update.driverName = fullName;
        if (user.numeroVehiculo) {
          update.driverVehicleNumber = user.numeroVehiculo;
        }
        if (Object.keys(update).length === 0) {
          skipped++;
          continue;
        }
        batch.update(doc.ref, update);
        pendingWrites++;
        updated++;
      }

      if (pendingWrites > 0) {
        await batch.commit();
      }

      lastDoc = snap.docs[snap.docs.length - 1];
      if (snap.docs.length < pageSize) break;
    }

    console.log(`backfillPayments: scanned=${scanned} updated=${updated} skipped=${skipped}`);
    return { ok: true, scanned, updated, skipped };
  },
);



// ───────────────────────────────────────────────────────────────────
//  inheritArchivedRecords — al re-registrarse con la misma cédula que
//  un usuario soft-deleted, transferir los pagos / viajes / gastos
//  históricos al nuevo UID para que el conductor vea su balance.
// ───────────────────────────────────────────────────────────────────
//
// Caso típico: el admin elimina a Haydee (soft-delete → archivedCedula
// guardada). Haydee se vuelve a crear cuenta con la misma cédula y el
// mismo tenant. Sin migración, sus $X de saldo previo quedan huérfanos
// (driverId apunta al UID viejo borrado). Con esta función:
//   - Busca users con archivedCedula == miCedula y associationId == mío
//     y status == 'deleted'.
//   - Para cada uno, transfiere TODOS sus pagos / trips / expenses al
//     nuevo UID con un campo 'inheritedFrom: oldUid' para auditoría.
//   - Marca el doc soft-deleted con 'migratedTo: newUid' para que no se
//     vuelva a migrar dos veces.
//
// Es callable y solo lo puede invocar el dueño del nuevo UID
// (request.auth.uid == data.newUid). Sin auth → throw.
//
// Es **idempotente**: si vuelve a correr, no hace nada porque el old
// user ya tiene migratedTo.

exports.inheritArchivedRecords = onCall(
  { region: "us-central1" },
  async (request) => {
    const auth = requireAuth(request);
    const newUid = auth.uid;

    // Cargar el usuario nuevo (yo) para sacar cedula + tenant.
    const myRef = db.collection("users").doc(newUid);
    const mySnap = await myRef.get();
    if (!mySnap.exists) {
      throw new HttpsError("not-found", "Tu doc de usuario no existe.");
    }
    const me = mySnap.data();
    const myCedula = (me.cedula || "").toString();
    const myAid = me.associationId;
    if (!myCedula || !myAid) {
      throw new HttpsError(
        "failed-precondition",
        "Faltan cedula o associationId en tu perfil.",
      );
    }

    // Buscar usuarios soft-deleted con misma cédula y mismo tenant.
    const candidates = await db
      .collection("users")
      .where("archivedCedula", "==", myCedula)
      .where("associationId", "==", myAid)
      .get();

    const ancestors = candidates.docs.filter((d) => {
      const data = d.data();
      return (
        d.id !== newUid &&
        data.status === "deleted" &&
        !data.migratedTo // todavía no se migró
      );
    });

    if (ancestors.length === 0) {
      return { ok: true, ancestorsFound: 0, migrated: { payments: 0, trips: 0, expenses: 0 } };
    }

    let movedPayments = 0;
    let movedTrips = 0;
    let movedExpenses = 0;

    for (const ancestor of ancestors) {
      const oldUid = ancestor.id;
      // Transferir payments del ancestor.
      const payments = await db
        .collection("payments")
        .where("driverId", "==", oldUid)
        .get();
      for (const chunk of chunkArray(payments.docs, 400)) {
        const batch = db.batch();
        for (const p of chunk) {
          batch.update(p.ref, {
            driverId: newUid,
            inheritedFrom: oldUid,
            // Refresca también el nombre denormalizado al actual.
            driverName: [me.name, me.lastname].filter(Boolean).join(" ").trim() || null,
            driverVehicleNumber: me.numeroVehiculo || null,
          });
          movedPayments++;
        }
        await batch.commit();
      }

      // Trips
      const trips = await db
        .collection("trips")
        .where("driverId", "==", oldUid)
        .get();
      for (const chunk of chunkArray(trips.docs, 400)) {
        const batch = db.batch();
        for (const t of chunk) {
          batch.update(t.ref, {
            driverId: newUid,
            inheritedFrom: oldUid,
          });
          movedTrips++;
        }
        await batch.commit();
      }

      // Expenses
      const expenses = await db
        .collection("expenses")
        .where("driverId", "==", oldUid)
        .get();
      for (const chunk of chunkArray(expenses.docs, 400)) {
        const batch = db.batch();
        for (const e of chunk) {
          batch.update(e.ref, {
            driverId: newUid,
            inheritedFrom: oldUid,
          });
          movedExpenses++;
        }
        await batch.commit();
      }

      // Marcar al ancestor como migrado.
      await ancestor.ref.update({
        migratedTo: newUid,
        migratedAt: FieldValue.serverTimestamp(),
      });
    }

    console.log(
      `inheritArchivedRecords: new=${newUid} ancestors=${ancestors.length} ` +
        `payments=${movedPayments} trips=${movedTrips} expenses=${movedExpenses}`,
    );
    return {
      ok: true,
      ancestorsFound: ancestors.length,
      migrated: {
        payments: movedPayments,
        trips: movedTrips,
        expenses: movedExpenses,
      },
    };
  },
);

function chunkArray(arr, size) {
  const chunks = [];
  for (let i = 0; i < arr.length; i += size) {
    chunks.push(arr.slice(i, i + size));
  }
  return chunks;
}

// ───────────────────────────────────────────────────────────────────
//  cleanupOrphanedDrivers — limpieza histórica de "drivers fantasma".
//
//  Recorre `drivers/` (filtra por associationId si se pasa) y para
//  cada doc verifica que su `users/{userId}` exista y NO esté marcado
//  como `status='deleted'`. Si está huérfano, lo apaga (isActive=false,
//  status='offline', currentPosition=null, archivedAt=now).
//
//  Esto repara los conductores que fueron eliminados ANTES de que el
//  fix de cascada en `deleteUser` existiera — quedaban con isActive=true
//  y aparecían duplicados en el modal "Agregar a la cola" y en el mapa.
//
//  Permisos: super-admin O admin de la asociación que se está limpiando.
//  Idempotente: vuelve a correrlo cuantas veces sea necesario.
// ───────────────────────────────────────────────────────────────────

exports.cleanupOrphanedDrivers = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { associationId } = request.data || {};

  const callerEmail = auth.token.email || "";
  const isSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);

  // Validar permisos:
  //  - super-admin puede limpiar cualquier asociación (o todas si no se
  //    pasa associationId)
  //  - admin solo puede limpiar la suya
  let scopedAid = associationId;
  if (!isSuper) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const callerData = callerSnap.exists ? callerSnap.data() : null;
    if (!callerData || callerData.role !== "admin") {
      throw new HttpsError("permission-denied", "Sin permisos.");
    }
    if (associationId && associationId !== callerData.associationId) {
      throw new HttpsError(
        "permission-denied",
        "Solo puedes limpiar tu asociación."
      );
    }
    scopedAid = callerData.associationId;
  }

  let driversQuery = db.collection("drivers");
  if (scopedAid) {
    driversQuery = driversQuery.where("associationId", "==", scopedAid);
  }
  const driversSnap = await driversQuery.get();

  const now = FieldValue.serverTimestamp();
  let scanned = 0;
  let cleaned = 0;
  const cleanedSummary = [];

  for (const d of driversSnap.docs) {
    scanned++;
    const data = d.data();
    if (data.archivedAt || data.deletedAt) continue; // ya limpio

    const userId = data.userId;
    let orphan = false;
    let reason = "";

    if (!userId) {
      orphan = true;
      reason = "sin userId";
    } else {
      const userSnap = await db.collection("users").doc(userId).get();
      if (!userSnap.exists) {
        orphan = true;
        reason = "users doc no existe";
      } else {
        const userData = userSnap.data();
        if (userData.status === "deleted" || userData.deletedAt) {
          orphan = true;
          reason = "user soft-deleted";
        }
      }
    }

    if (!orphan) continue;

    await d.ref.update({
      isActive: false,
      archivedAt: now,
      deletedAt: now,
      currentPosition: null,
      currentLat: null,
      currentLng: null,
      currentLatitude: null,
      currentLongitude: null,
      status: "offline",
      inQueueAt: null,
      updatedAt: now,
    });
    cleaned++;
    cleanedSummary.push({
      id: d.id,
      vehicleNumber: data.vehicleNumber || null,
      reason,
    });
  }

  return {
    ok: true,
    scanned,
    cleaned,
    associationId: scopedAid || "(todas)",
    cleanedSummary,
  };
});

// ───────────────────────────────────────────────────────────────────
//  markStaleDriversOffline — cron de presencia.
//
//  Cada conductor con la app viva escribe `updatedAt = now` en cada
//  update de GPS (cada 5-30s según movimiento). Si un conductor lleva
//  más de [staleMinutes] sin actualizar, asumimos que su sesión murió
//  (app cerrada, batería agotada, sin red, crash) y lo apagamos:
//    isActive=false, status='offline', currentPosition=null, inQueueAt=null
//
//  Esto resuelve el bug "el conductor se ve en el mapa pero no escucha
//  audio porque cerró sesión / mató la app". La operadora deja de verlo
//  como disponible y los demás dejan de esperarlo.
//
//  Cron cada 2 minutos. Threshold: 3 minutos sin updatedAt.
// ───────────────────────────────────────────────────────────────────

const STALE_MINUTES = 3;

async function _runMarkStaleDriversOffline() {
  const cutoffMs = Date.now() - STALE_MINUTES * 60 * 1000;
  const cutoff = Timestamp.fromMillis(cutoffMs);

  const snap = await db
    .collection("drivers")
    .where("isActive", "==", true)
    .where("updatedAt", "<", cutoff)
    .limit(500)
    .get();

  let scanned = snap.size;
  let marked = 0;

  for (const d of snap.docs) {
    const data = d.data();
    if (!data.updatedAt) continue;
    try {
      await d.ref.update({
        isActive: false,
        status: "offline",
        currentPosition: null,
        currentLatitude: null,
        currentLongitude: null,
        inQueueAt: null,
        offlineReason: "stale_no_heartbeat",
        offlineAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      marked++;
    } catch (e) {
      console.warn(
        `markStaleDriversOffline: ${d.id} update falló`,
        e.message,
      );
    }
  }

  return { ok: true, scanned, marked, staleMinutes: STALE_MINUTES };
}

exports.markStaleDriversOffline = onSchedule(
  {
    schedule: "*/2 * * * *",
    timeZone: "America/Guayaquil",
    timeoutSeconds: 60,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runMarkStaleDriversOffline();
    if (summary.marked > 0) {
      console.log("markStaleDriversOffline:", JSON.stringify(summary));
    }
    return summary;
  },
);

exports.markStaleDriversOfflineNow = onCall({}, async (request) => {
  requireSuperAdmin(request);
  const summary = await _runMarkStaleDriversOffline();
  return summary;
});

