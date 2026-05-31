const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten, onDocumentUpdated, onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { setGlobalOptions } = require("firebase-functions/v2");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const { getMessaging } = require("firebase-admin/messaging");
const { RtcTokenBuilder, RtcRole } = require("agora-token");
const { buildLiveKitToken } = require("./lib/livekitToken");
const { buildNotification, tokensForAssociation } = require("./lib/groupChat");
const {
  isTransitionToFinalized,
  isFirstRating,
  computeNewAverage,
  fareForHour,
  localDateHourEC,
} = require("./lib/tripStats");
const { computeNextDueAtForUser, decideDuesAction } = require("./lib/dueDate");

initializeApp();
const db = getFirestore();

// Tope global de instancias: evita fuga de costo ante un pico o un bucle de
// escrituras sin estrangular la operación normal. NO seteamos region ni memory
// aquí (los overrides por función siguen vigentes).
setGlobalOptions({ maxInstances: 10 });

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
// LiveKit self-hosted (Oracle Cloud). Reemplazo gradual de Agora detrás del
// feature flag `associations/{id}.voiceProvider`. Setear con:
//   firebase functions:secrets:set LIVEKIT_API_KEY
//   firebase functions:secrets:set LIVEKIT_API_SECRET
//   firebase functions:secrets:set LIVEKIT_URL   (= wss://livekit.it-services.center)
const LIVEKIT_API_KEY = defineSecret("LIVEKIT_API_KEY");
const LIVEKIT_API_SECRET = defineSecret("LIVEKIT_API_SECRET");
const LIVEKIT_URL = defineSecret("LIVEKIT_URL");
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
//  generateLiveKitToken — token JWT para walkie-talkie (LiveKit)
//
//  Equivalente a generateAgoraToken pero para el servidor LiveKit
//  self-hosted. El cliente (LiveKitVoiceProvider, Fase 3) llama a esta
//  función con el mismo `channelName` que usaría en Agora. Devuelve la
//  URL del server + el JWT con grant de roomJoin/publish/subscribe.
//
//  La `identity` del token es el uid de Firebase (único por usuario),
//  lo que LiveKit usa como identificador del participante en la sala.
// ───────────────────────────────────────────────────────────────────

exports.generateLiveKitToken = onCall(
  {
    secrets: [LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_URL],
    enforceAppCheck: false,
  },
  async (request) => {
    const auth = requireAuth(request);

    const { channelName } = request.data || {};

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

    const apiKey = LIVEKIT_API_KEY.value();
    const apiSecret = LIVEKIT_API_SECRET.value();
    const url = LIVEKIT_URL.value();

    if (!apiKey || !apiSecret || !url) {
      throw new HttpsError(
        "failed-precondition",
        "LIVEKIT_API_KEY/LIVEKIT_API_SECRET/LIVEKIT_URL no están configurados en el servidor."
      );
    }

    // TTL alineado con Agora (24h) para cubrir un turno completo del
    // conductor sin refresco a mitad de jornada.
    return buildLiveKitToken({
      apiKey,
      apiSecret,
      url,
      identity: auth.uid,
      channelName,
      ttlSeconds: 86400,
    });
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

  // Materializar nextDueAt (cuota interna) de forma ADITIVA. La aprobación
  // ocurre ahora, así que usamos la fecha actual como approvedAt para el
  // cómputo preciso (el campo approvedAt persistido sigue siendo serverTimestamp).
  const aSnapForDue = await db.collection("associations").doc(aid).get();
  const billingConfigForDue = aSnapForDue.exists
    ? aSnapForDue.data().billingConfig || null
    : null;
  const nextDueAt = computeNextDueAtForUser({
    approvedAt: new Date(),
    lastPayment: null,
    billingConfig: billingConfigForDue,
  });

  await driverRef.update({
    status: "active",
    approvedBy: auth.uid,
    approvedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    nextDueAt: nextDueAt ? Timestamp.fromDate(nextDueAt) : null,
    lastValidatedPaymentAt: null,
    dueComputeVersion: 1,
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

  const cuotaIncluida = data.cuotaIncluida != null ? Number(data.cuotaIncluida) : null;
  const multaIncluida = data.multaIncluida != null ? Number(data.multaIncluida) : null;

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
  const paymentDoc = {
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
  };
  if (cuotaIncluida !== null && cuotaIncluida > 0) {
    paymentDoc.cuotaIncluida = cuotaIncluida;
  }
  if (multaIncluida !== null && multaIncluida > 0) {
    paymentDoc.multaIncluida = multaIncluida;
  }
  await ref.set(paymentDoc);

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

    // Materializar nextDueAt (ADITIVO): si el pago validado es la cuota interna
    // (concepto == billingConfig.defaultConcept), recalcular el próximo
    // vencimiento usando este pago como último pago validado. NO altera el
    // path de reactivación de arriba.
    const aSnapForDue = await db
      .collection("associations")
      .doc(payment.associationId)
      .get();
    const billingConfigForDue = aSnapForDue.exists
      ? aSnapForDue.data().billingConfig || null
      : null;
    const defaultConcept = billingConfigForDue
      ? billingConfigForDue.defaultConcept
      : null;
    if (billingConfigForDue && payment.concept === defaultConcept) {
      // El pago se acaba de validar con validatedAt=serverTimestamp (pendiente),
      // así que usamos la fecha actual como validatedAt para el cómputo preciso.
      const validatedAtForDue = new Date();
      const nextDueAt = computeNextDueAtForUser({
        approvedAt: d.approvedAt || null,
        lastPayment: { validatedAt: validatedAtForDue },
        billingConfig: billingConfigForDue,
      });
      await driverSnap.ref.update({
        nextDueAt: nextDueAt ? Timestamp.fromDate(nextDueAt) : null,
        lastValidatedPaymentAt: Timestamp.fromDate(validatedAtForDue),
        dueComputeVersion: 1,
        updatedAt: FieldValue.serverTimestamp(),
      });
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
    let fechaPago = payment.paymentDate || payment.validatedAt || null;
    const metodoPago = (payment.proof && payment.proof.method) ? payment.proof.method : null;
    const beneficiario = payment.driverName ||
      (payment.driverVehicleNumber
        ? `Unidad #${payment.driverVehicleNumber}`
        : null);
    const comprobanteUrl = (payment.proof && payment.proof.photoUrl) ? payment.proof.photoUrl : null;
    const vehNum = payment.driverVehicleNumber || null;

    const cuotaIncluida = payment.cuotaIncluida || null;
    const multaIncluida = payment.multaIncluida || null;

    if (multaIncluida > 0 && cuotaIncluida > 0) {
      // Caso híbrido: 2 movimientos — cuota base + multa
      const cashflowCuotaRef = db.collection("cashflow").doc();
      await cashflowCuotaRef.set({
        associationId: payment.associationId,
        tipo: "ingreso",
        categoria: payment.concept || "cuota",
        subcategoria: null,
        monto: cuotaIncluida,
        fecha: fechaPago || FieldValue.serverTimestamp(),
        metodoPago,
        beneficiario,
        descripcion: `Pago validado · ${payment.concept || "cuota"}`,
        comprobanteUrl,
        linkedPaymentId: ref.id,
        autoGenerated: true,
        createdBy: auth.uid,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      const cashflowMultaRef = db.collection("cashflow").doc();
      await cashflowMultaRef.set({
        associationId: payment.associationId,
        tipo: "ingreso",
        categoria: "multa",
        subcategoria: null,
        monto: multaIncluida,
        fecha: fechaPago || FieldValue.serverTimestamp(),
        metodoPago,
        beneficiario,
        descripcion: `Multa por atraso · Unidad #${vehNum}`,
        comprobanteUrl,
        linkedPaymentId: ref.id,
        autoGenerated: true,
        createdBy: auth.uid,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    } else {
      // Caso normal: 1 solo movimiento con el monto entero
      const cashflowRef = db.collection("cashflow").doc();
      // Timestamp de Firestore → lo usamos tal cual; si es null usamos serverTimestamp
      await cashflowRef.set({
        associationId: payment.associationId,
        tipo: "ingreso",
        categoria: payment.concept || "cuota",
        subcategoria: null,
        monto: payment.amount,
        fecha: fechaPago || FieldValue.serverTimestamp(),
        metodoPago,
        beneficiario,
        descripcion: `Pago validado · ${payment.concept || "cuota"}`,
        comprobanteUrl,
        linkedPaymentId: ref.id,
        autoGenerated: true,
        createdBy: auth.uid,
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
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

    // Materializar nextDueAt (ADITIVO): tras anular, el último pago no anulado
    // pudo cambiar; recomputamos. NO toca la lógica de bloqueo por pago_anulado.
    // _lastValidatedPayment ya filtra los anulados (este pago ya tiene voidedAt).
    const driverDueSnap = await db.collection("users").doc(p.driverId).get();
    const driverDue = driverDueSnap.exists ? driverDueSnap.data() : null;
    const aSnapForDue = await db
      .collection("associations")
      .doc(p.associationId)
      .get();
    const billingConfigForDue = aSnapForDue.exists
      ? aSnapForDue.data().billingConfig || null
      : null;
    if (driverDue && billingConfigForDue) {
      const lastPayment = await _lastValidatedPayment(p.driverId, p.associationId);
      const nextDueAt = computeNextDueAtForUser({
        approvedAt: driverDue.approvedAt || null,
        lastPayment: lastPayment ? { validatedAt: lastPayment.validatedAt } : null,
        billingConfig: billingConfigForDue,
      });
      await driverDueSnap.ref.update({
        nextDueAt: nextDueAt ? Timestamp.fromDate(nextDueAt) : null,
        lastValidatedPaymentAt:
          lastPayment && lastPayment.validatedAt
            ? lastPayment.validatedAt
            : null,
        dueComputeVersion: 1,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
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
//  requestVehicleChange — conductor pide cambio de unidad.
//  Valida: no tiene otro request pending + no excede 2 aprobados/30d.
// ──────────────────────────────────────────────────────────────────

exports.requestVehicleChange = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { newPlate, newVehicleNumber, newFotoVehiculo, reason } = request.data || {};

  if (!newPlate || !newVehicleNumber || !reason || reason.length < 10) {
    throw new HttpsError("invalid-argument",
      "Campos requeridos: newPlate, newVehicleNumber, reason (mín 10 chars).");
  }

  const userSnap = await db.collection("users").doc(auth.uid).get();
  if (!userSnap.exists) {
    throw new HttpsError("not-found", "Usuario no encontrado.");
  }
  const user = userSnap.data();

  if (!["conductor", "admin"].includes(user.role)) {
    throw new HttpsError("permission-denied",
      "Solo conductores pueden solicitar cambio de unidad.");
  }

  // Validación: no más de 1 pending simultáneo
  const pendingSnap = await db.collection("vehicleChangeRequests")
    .where("driverId", "==", auth.uid)
    .where("status", "==", "pending")
    .limit(1)
    .get();
  if (!pendingSnap.empty) {
    throw new HttpsError("failed-precondition",
      "Ya tienes una solicitud pendiente. Espera la respuesta antes de crear otra.");
  }

  // Validación: máximo 2 aprobados en los últimos 30 días
  const thirtyDaysAgo = new Date();
  thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
  const recentApprovedSnap = await db.collection("vehicleChangeRequests")
    .where("driverId", "==", auth.uid)
    .where("status", "==", "approved")
    .where("approvedAt", ">=", Timestamp.fromDate(thirtyDaysAgo))
    .get();
  if (recentApprovedSnap.size >= 2) {
    throw new HttpsError("failed-precondition",
      "Has alcanzado el máximo de 2 cambios aprobados en los últimos 30 días.");
  }

  const now = FieldValue.serverTimestamp();
  const docRef = db.collection("vehicleChangeRequests").doc();
  await docRef.set({
    driverId: auth.uid,
    driverName: `${user.name || ""} ${user.lastname || ""}`.trim(),
    associationId: user.associationId,
    status: "pending",
    oldPlate: user.placa || "",
    oldVehicleNumber: user.numeroVehiculo || "",
    oldFotoVehiculo: user.fotoVehiculo || null,
    newPlate,
    newVehicleNumber,
    newFotoVehiculo: newFotoVehiculo || null,
    reason,
    createdAt: now,
    updatedAt: now,
  });

  return { ok: true, requestId: docRef.id };
});

// ──────────────────────────────────────────────────────────────────
//  approveVehicleChange — admin u operadora aprueba un cambio.
// ──────────────────────────────────────────────────────────────────

exports.approveVehicleChange = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { requestId } = request.data || {};
  if (!requestId) throw new HttpsError("invalid-argument", "requestId requerido.");

  const reqRef = db.collection("vehicleChangeRequests").doc(requestId);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists) throw new HttpsError("not-found", "Solicitud no existe.");
  const r = reqSnap.data();
  if (r.status !== "pending") {
    throw new HttpsError("failed-precondition",
      `Solo solicitudes pending; este está en ${r.status}.`);
  }

  // Permisos: admin u operadora del mismo tenant, O super-admin
  const callerEmail = auth.token.email || "";
  const isSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);
  if (!isSuper) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const caller = callerSnap.exists ? callerSnap.data() : null;
    if (!caller || !["admin", "operadora"].includes(caller.role) ||
        caller.associationId !== r.associationId) {
      throw new HttpsError("permission-denied",
        "Solo admin u operadora de la asociación pueden aprobar.");
    }
  }

  const callerInfoSnap = await db.collection("users").doc(auth.uid).get();
  const callerInfo = callerInfoSnap.data() || {};
  const callerName = `${callerInfo.name || ""} ${callerInfo.lastname || ""}`.trim();

  const now = FieldValue.serverTimestamp();

  // Update request + driver doc en batch
  const batch = db.batch();
  batch.update(reqRef, {
    status: "approved",
    approvedBy: auth.uid,
    approvedByName: callerName || auth.uid,
    approvedAt: now,
    updatedAt: now,
  });
  batch.update(db.collection("users").doc(r.driverId), {
    placa: r.newPlate,
    numeroVehiculo: r.newVehicleNumber,
    fotoVehiculo: r.newFotoVehiculo || null,
    updatedAt: now,
  });
  await batch.commit();

  // FCM al conductor
  await _sendFcmToUid(r.driverId, {
    title: "Cambio de unidad aprobado",
    body: `Tu unidad ahora es #${r.newVehicleNumber} placa ${r.newPlate}.`,
  }).catch(() => {});

  return { ok: true };
});

// ──────────────────────────────────────────────────────────────────
//  rejectVehicleChange — admin u operadora rechaza.
// ──────────────────────────────────────────────────────────────────

exports.rejectVehicleChange = onCall({}, async (request) => {
  const auth = requireAuth(request);
  const { requestId, rejectReason } = request.data || {};
  if (!requestId) throw new HttpsError("invalid-argument", "requestId requerido.");
  if (!rejectReason || rejectReason.length < 5) {
    throw new HttpsError("invalid-argument", "rejectReason requerido (mín 5 chars).");
  }

  const reqRef = db.collection("vehicleChangeRequests").doc(requestId);
  const reqSnap = await reqRef.get();
  if (!reqSnap.exists) throw new HttpsError("not-found", "Solicitud no existe.");
  const r = reqSnap.data();
  if (r.status !== "pending") {
    throw new HttpsError("failed-precondition", "Solo solicitudes pending.");
  }

  // Permisos: admin u operadora del mismo tenant
  const callerEmail = auth.token.email || "";
  const isSuper = SUPER_ADMIN_EMAILS.includes(callerEmail);
  if (!isSuper) {
    const callerSnap = await db.collection("users").doc(auth.uid).get();
    const caller = callerSnap.exists ? callerSnap.data() : null;
    if (!caller || !["admin", "operadora"].includes(caller.role) ||
        caller.associationId !== r.associationId) {
      throw new HttpsError("permission-denied",
        "Solo admin u operadora de la asociación pueden rechazar.");
    }
  }

  const callerInfoSnap = await db.collection("users").doc(auth.uid).get();
  const callerInfo = callerInfoSnap.data() || {};
  const callerName = `${callerInfo.name || ""} ${callerInfo.lastname || ""}`.trim();

  const now = FieldValue.serverTimestamp();
  await reqRef.update({
    status: "rejected",
    rejectedBy: auth.uid,
    rejectedByName: callerName || auth.uid,
    rejectedAt: now,
    rejectReason,
    updatedAt: now,
  });

  await _sendFcmToUid(r.driverId, {
    title: "Cambio de unidad rechazado",
    body: `Motivo: ${rejectReason}`,
  }).catch(() => {});

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
    multaPorDiaAtraso: Math.max(0, Number(billingConfig.multaPorDiaAtraso) || 0),
  };

  // Leer config previa para detectar cambios que afectan el cómputo de
  // vencimiento (período, dueDay o amount).
  const aRef = db.collection("associations").doc(associationId);
  const aSnapPrev = await aRef.get();
  const prevCfg = aSnapPrev.exists ? aSnapPrev.data().billingConfig || {} : {};

  await aRef.update({
    billingConfig: cleaned,
    updatedAt: FieldValue.serverTimestamp(),
  });

  // Si cambió período/dueDay/amount, recomputar nextDueAt de los conductores
  // de esta asociación (ADITIVO; en batches de 450). Reusa _lastValidatedPayment
  // por conductor (poco frecuente, aceptable).
  const dueRelevantChanged =
    Number(prevCfg.amount || 0) !== cleaned.amount ||
    Number(prevCfg.dueDay || 1) !== cleaned.dueDay ||
    (prevCfg?.period?.every || 1) !== cleaned.period.every ||
    (prevCfg?.period?.unit || "month") !== cleaned.period.unit;

  if (dueRelevantChanged) {
    const driversSnap = await db
      .collection("users")
      .where("associationId", "==", associationId)
      .where("role", "in", ["conductor", "admin"])
      .select("approvedAt", "role")
      .get();

    const CHUNK = 450;
    const docs = driversSnap.docs;
    for (let i = 0; i < docs.length; i += CHUNK) {
      const slice = docs.slice(i, i + CHUNK);
      const batch = db.batch();
      for (const uDoc of slice) {
        const u = uDoc.data();
        const lastPayment = await _lastValidatedPayment(uDoc.id, associationId);
        const nextDueAt = computeNextDueAtForUser({
          approvedAt: u.approvedAt || null,
          lastPayment: lastPayment ? { validatedAt: lastPayment.validatedAt } : null,
          billingConfig: cleaned,
        });
        batch.set(
          uDoc.ref,
          {
            nextDueAt: nextDueAt ? Timestamp.fromDate(nextDueAt) : null,
            lastValidatedPaymentAt:
              lastPayment && lastPayment.validatedAt
                ? lastPayment.validatedAt
                : null,
            dueComputeVersion: 1,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true }
        );
      }
      await batch.commit();
    }
  }

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
    memory: "256MiB",
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
    memory: "256MiB",
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

/// Helper: envía un multicast en lotes de 500 y borra de Firestore los
/// fcmToken muertos (UNREGISTERED / inválidos) que reporte FCM. `entries` es
/// un array paralelo de { token, ref } donde `ref` es la DocumentReference del
/// user dueño del token. `message` debe traer ya notification/data/android/apns
/// (sin `tokens`). Devuelve { sent, pruned }.
async function _sendMulticastAndPrune(entries, message) {
  const DEAD = new Set([
    "messaging/registration-token-not-registered",
    "messaging/invalid-registration-token",
    "messaging/invalid-argument",
  ]);
  let sent = 0;
  let pruned = 0;
  for (let i = 0; i < entries.length; i += 500) {
    const chunk = entries.slice(i, i + 500);
    const resp = await getMessaging().sendEachForMulticast({
      ...message,
      tokens: chunk.map((e) => e.token),
    });
    sent += resp.successCount;
    const batch = db.batch();
    let toPrune = 0;
    resp.responses.forEach((r, idx) => {
      if (!r.success && r.error && DEAD.has(r.error.code)) {
        batch.update(chunk[idx].ref, { fcmToken: FieldValue.delete() });
        toPrune++;
      }
    });
    if (toPrune > 0) {
      await batch.commit();
      pruned += toPrune;
    }
  }
  return { sent, pruned };
}

/// Helper interno para enviar FCM a un uid usando el fcmToken guardado.
async function _sendFcmToUid(uid, payload, data = {}) {
  const u = await db.collection("users").doc(uid).get();
  const token = u.data()?.fcmToken;
  if (!token) return;
  await getMessaging().send({
    token,
    notification: { title: payload.title, body: payload.body },
    data: Object.fromEntries(
      Object.entries(data).map(([k, v]) => [k, String(v)]),
    ),
    // android.priority=high + android.notification.sound=default fuerza
    // que el push suene y vibre en el shade aún si el shade está
    // silenciado a nivel "low priority". Combinado con el canal
    // 'taxi_default' (creado client-side con playSound: true) el aviso
    // suena tanto en background como cuando el FcmMessageHandler lo
    // re-muestra en foreground.
    android: {
      priority: "high",
      notification: {
        sound: "default",
        channelId: "taxi_default",
        defaultSound: true,
        defaultVibrateTimings: true,
      },
    },
    apns: {
      payload: { aps: { sound: "default" } },
    },
  });
}

/// Helper: envía la MISMA push a todos los usuarios de una asociación que
/// tengan alguno de los `roles` indicados y estén `active`. Lee tokens de
/// `users/{uid}.fcmToken` y manda un multicast. `data` opcional viaja como
/// payload de datos (para enrutar el tap en el cliente). Devuelve cuántos
/// tokens se intentaron. Silencioso ante ausencia de tokens (no rompe el
/// flujo que lo invoca).
async function _sendFcmToRoles(associationId, roles, payload, data = {}) {
  if (!associationId || !Array.isArray(roles) || roles.length === 0) return 0;
  // Filtramos por associationId + status en la query y el rol en código
  // (mismo patrón que dispatchScheduledNotifications) para no depender de un
  // índice compuesto con `role in`.
  const snap = await db
    .collection("users")
    .where("associationId", "==", associationId)
    .where("status", "in", ["active", "paymentPending"])
    .select("fcmToken", "role")
    .get();
  const entries = [];
  for (const u of snap.docs) {
    const d = u.data();
    if (!roles.includes(d.role)) continue;
    const t = d.fcmToken;
    if (typeof t === "string" && t.length > 0) entries.push({ token: t, ref: u.ref });
  }
  if (entries.length === 0) return 0;
  const { sent, pruned } = await _sendMulticastAndPrune(entries, {
    notification: { title: payload.title, body: payload.body },
    data: Object.fromEntries(
      Object.entries(data).map(([k, v]) => [k, String(v)]),
    ),
    android: {
      priority: "high",
      notification: {
        sound: "default",
        channelId: "taxi_default",
        defaultSound: true,
        defaultVibrateTimings: true,
      },
    },
    apns: { payload: { aps: { sound: "default" } } },
  });
  console.log(`[_sendFcmToRoles] sent=${sent} pruned=${pruned} tokens=${entries.length}`);
  return entries.length;
}

/// Helper: envía la MISMA push a TODOS los usuarios activos de la plataforma
/// (todas las asociaciones) cuyo rol esté en `roles`. Usado para avisos
/// globales como los eventos de Quito.
///
/// OPTIMIZACIÓN DE COSTO (audit §4): antes leía TODA la colección `users` en
/// cada envío (la query más cara a escala). Ahora usa FCM topics por rol:
/// envía un único mensaje a `role_<rol>` por cada rol, sin leer Firestore.
/// El cliente (app) suscribe a cada usuario al topic `role_<su rol>` al iniciar
/// sesión (convención: role_conductor, role_admin, role_operadora).
///
/// NOTA DE TRANSICIÓN: con topics solo reciben los usuarios cuya app los
/// suscribió a `role_<rol>`. Como se va a redistribuir el APK nuevo (que
/// suscribe), todos los usuarios activos quedarán suscritos. Es aceptable para
/// este broadcast (eventos Quito).
///
/// Conserva la firma `(roles, payload, data)`. Devuelve el nº de topics a los
/// que se envió (ya no el nº de tokens). No limpia tokens muertos (FCM gestiona
/// la entrega por topic).
async function _sendFcmGlobalToRoles(roles, payload, data = {}) {
  if (!Array.isArray(roles) || roles.length === 0) return 0;
  const dataStr = Object.fromEntries(
    Object.entries(data).map(([k, v]) => [k, String(v)]),
  );
  let sent = 0;
  for (const role of roles) {
    try {
      await getMessaging().send({
        topic: `role_${role}`,
        notification: { title: payload.title, body: payload.body },
        data: dataStr,
        android: {
          priority: "high",
          notification: {
            sound: "default",
            channelId: "taxi_default",
            defaultSound: true,
            defaultVibrateTimings: true,
          },
        },
        apns: { payload: { aps: { sound: "default" } } },
      });
      sent++;
    } catch (e) {
      console.warn(`_sendFcmGlobalToRoles topic role_${role} fail:`, e.message);
    }
  }
  console.log(`_sendFcmGlobalToRoles: enviado a ${sent} topics (${roles.join(",")})`);
  return sent;
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

// ═══════════════════════════════════════════════════════════════════
//  enforceMembershipDues — cron unificado de morosidad (Bloque D / Fase 2).
//
//  Estado: SHADOW. Corre a las 00:45 (después de los 3 crones viejos:
//  enforcePayments 00:00, checkSubscriptions 00:05, checkDriverDues 00:30).
//  Los 3 viejos SIGUEN siendo la fuente de verdad: este cron NO escribe
//  status mientras `mode` != "live" (y "live" aún no está habilitado).
//
//  Modo leído de la bandera Firestore `app_config/duesEnforcement.mode`:
//    - "off"    → no hace nada.
//    - "shadow" → calcula qué bloquearía/reactivaría y lo loguea en
//                 `duesShadowLog/{YYYY-MM-DD}` (NO escribe status). DEFAULT
//                 seguro si el doc no existe o falla la lectura.
//    - "live"   → reservado; por ahora se comporta como shadow + warn
//                 (el cutover real a escritura es un paso posterior).
//
//  El ahorro N+1: una sola query de candidatos (status==active &
//  nextDueAt<=now) en vez de escanear todos los users por asociación.
//  `_hasActivePermit` se ejecuta SOLO sobre los candidatos vencidos.
// ═══════════════════════════════════════════════════════════════════

const DUES_ENFORCEMENT_FLAG = { collection: "app_config", doc: "duesEnforcement" };

/// Lee el modo de la bandera. Default "shadow" (seguro: nunca escribe status)
/// si el doc no existe o la lectura falla.
async function _readDuesEnforcementMode() {
  try {
    const snap = await db
      .collection(DUES_ENFORCEMENT_FLAG.collection)
      .doc(DUES_ENFORCEMENT_FLAG.doc)
      .get();
    if (!snap.exists) return "shadow";
    const mode = snap.data()?.mode;
    if (mode === "off" || mode === "shadow" || mode === "live") return mode;
    return "shadow";
  } catch (e) {
    console.error("[enforceMembershipDues] flag read failed, default shadow", e);
    return "shadow";
  }
}

/// Módulo conductores en modo read-only: calcula qué uids se BLOQUEARÍAN y
/// cuáles se REACTIVARÍAN, sin escribir nada. Devuelve { wouldBlock, wouldReactivate }.
/// Usa la decisión pura `decideDuesAction` para cada candidato.
async function _computeDriverDuesShadow(now) {
  const wouldBlock = [];
  const wouldReactivate = [];

  // ── Candidatos a BLOQUEAR: activos con vencimiento <= now ──
  // Una sola query (índice users(status, nextDueAt)); sin N+1.
  const blockSnap = await db
    .collection("users")
    .where("status", "==", "active")
    .where("nextDueAt", "<=", now)
    .select("nextDueAt", "approvedAt", "role", "associationId")
    .get();

  // `_hasActivePermit` solo se evalúa sobre estos candidatos (decenas),
  // que es lo que elimina el N+1 sobre TODOS los conductores.
  for (const uDoc of blockSnap.docs) {
    const u = uDoc.data();
    // Pre-filtro de rol barato para no consultar permisos de no-elegibles.
    if (!["conductor", "admin"].includes(u.role)) continue;
    const hasPermit = await _hasActivePermit(uDoc.id, u.nextDueAt?.toDate?.() || u.nextDueAt);
    const action = decideDuesAction({
      status: "active",
      role: u.role,
      nextDueAt: u.nextDueAt,
      now,
      hasPermit,
    });
    if (action === "WOULD_BLOCK") wouldBlock.push(uDoc.id);
  }

  // ── Candidatos a REACTIVAR: bloqueados por cuota con vencimiento futuro ──
  const reactSnap = await db
    .collection("users")
    .where("status", "==", "paymentBlocked")
    .where("blockReason", "==", "cuota_vencida")
    .where("nextDueAt", ">", now)
    .select("nextDueAt", "role")
    .get();

  for (const uDoc of reactSnap.docs) {
    const u = uDoc.data();
    const action = decideDuesAction({
      status: "paymentBlocked",
      role: u.role,
      blockReason: "cuota_vencida",
      nextDueAt: u.nextDueAt,
      now,
    });
    if (action === "WOULD_REACTIVATE") wouldReactivate.push(uDoc.id);
  }

  return { wouldBlock, wouldReactivate };
}

/// Módulo SaaS de asociaciones en modo read-only: replica el CÁLCULO de
/// `_runSubscriptionCheck` (gracia 3d, expired/active) SIN escribir nada.
/// NO modifica la función vieja: duplica solo la decisión en read-only.
/// Devuelve { wouldExpire: [assocIds], wouldReactivate: [assocIds] }.
async function _computeSubscriptionsShadow() {
  const now = new Date();
  const wouldExpire = [];
  const wouldReactivate = [];

  const associationsSnap = await db.collection("associations").get();
  for (const aDoc of associationsSnap.docs) {
    const a = aDoc.data();
    const trialEndsAt = a.trialEndsAt?.toDate?.() || a.trialEndsAt || null;
    const paidUntil = a.paidUntil?.toDate?.() || a.paidUntil || null;
    const expiresAt = paidUntil || trialEndsAt;
    if (!expiresAt) continue; // legacy: no se toca

    const isExpired = expiresAt < now;
    const newStatus = isExpired ? "expired" : "active";
    if (a.status !== newStatus) {
      if (newStatus === "expired") wouldExpire.push(aDoc.id);
      else wouldReactivate.push(aDoc.id);
    }
  }

  return { wouldExpire, wouldReactivate };
}

/// Núcleo del cron: lee modo, calcula shadow y persiste el resumen en
/// `duesShadowLog/{YYYY-MM-DD}`. NO escribe status en ningún caso por ahora.
async function _runEnforceMembershipDues() {
  const now = Timestamp.now();
  const mode = await _readDuesEnforcementMode();
  const dateKey = now.toDate().toISOString().substring(0, 10); // YYYY-MM-DD (UTC)

  console.log(`[enforceMembershipDues] start mode=${mode} ${now.toDate().toISOString()}`);

  if (mode === "off") {
    console.log("[enforceMembershipDues] mode=off, no-op");
    return {
      mode,
      counts: { wouldBlock: 0, wouldReactivate: 0 },
      wouldBlock: [],
      wouldReactivate: [],
      subscriptions: { wouldExpire: [], wouldReactivate: [] },
    };
  }

  if (mode === "live") {
    // Branch preparado. El cutover real a escritura de status es un paso
    // posterior con revisión del dueño: por ahora se comporta como shadow.
    console.warn("[enforceMembershipDues] live mode not yet enabled — running as shadow");
  }

  const drivers = await _computeDriverDuesShadow(now);
  const subscriptions = await _computeSubscriptionsShadow();

  const summary = {
    runAt: now,
    mode,
    wouldBlock: drivers.wouldBlock,
    wouldReactivate: drivers.wouldReactivate,
    counts: {
      wouldBlock: drivers.wouldBlock.length,
      wouldReactivate: drivers.wouldReactivate.length,
    },
    subscriptions: {
      wouldExpire: subscriptions.wouldExpire,
      wouldReactivate: subscriptions.wouldReactivate,
    },
  };

  // Persistir el resumen para comparar contra lo que hicieron los crones viejos.
  await db
    .collection("duesShadowLog")
    .doc(dateKey)
    .set(summary, { merge: true });

  console.log(
    "[enforceMembershipDues] summary",
    JSON.stringify({
      mode,
      counts: summary.counts,
      wouldBlock: summary.wouldBlock,
      wouldReactivate: summary.wouldReactivate,
      subscriptions: summary.subscriptions,
    }),
  );

  return summary;
}

exports.enforceMembershipDues = onSchedule(
  {
    schedule: "45 0 * * *", // 00:45 — después de los 3 crones viejos
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    return await _runEnforceMembershipDues();
  },
);

/// Trigger manual super-admin para disparar el shadow sin esperar a las 00:45.
exports.enforceMembershipDuesNow = onCall({}, async (request) => {
  requireSuperAdmin(request);
  const summary = await _runEnforceMembershipDues();
  // `runAt` es un Timestamp; devolverlo como ISO para el cliente.
  return {
    ok: true,
    mode: summary.mode,
    counts: summary.counts,
    wouldBlock: summary.wouldBlock,
    wouldReactivate: summary.wouldReactivate,
    subscriptions: summary.subscriptions,
  };
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
Usa búsqueda en tiempo real para encontrar los eventos públicos previstos
para HOY (${dateLabel}, zona horaria America/Guayaquil) en Quito, el Distrito
Metropolitano, los valles (Cumbayá, Tumbaco, Los Chillos) y Sangolquí que
CONCENTREN PÚBLICO MASIVO y por tanto generen demanda real de taxis.

OBJETIVO: ayudar al taxista a saber dónde habrá aglomeración de gente para
conseguir más carreras. Solo importan eventos que concentran público (=
demanda de taxi). Si HOY no hay eventos de ese tipo (p. ej. un día tranquilo),
la respuesta correcta es vacío: devolver {"events":[]} es válido y PREFERIBLE
a inventar o forzar un evento. NUNCA fabriques ni fuerces eventos; un vacío
honesto vale más que un evento falso.

QUÉ INCLUIR (eventos con aglomeración / demanda de taxi):
conciertos, recitales, espectáculos musicales, teatro, ballet, ópera, danza,
stand-up, eventos deportivos masivos, ferias y festivales grandes. En recintos
como Coliseo General Rumiñahui, Plaza de Toros, Teatro Nacional Sucre, Teatro
Bolívar, Teatro México, Teatro San Gabriel, Ágora de la Casa de la Cultura,
estadios y centros de eventos grandes.

QUÉ EXCLUIR (sin público masivo, NO sirven al taxista):
eventos administrativos o municipales, reuniones, sesiones, ruedas de prensa,
trámites, actos protocolarios y cualquier cosa SIN público masivo. Ejemplo:
"un evento del municipio para administrativos" NO sirve; "un concierto en el
Coliseo Rumiñahui" SÍ sirve.

REVISA Y CONTRASTA OBLIGATORIAMENTE estas fuentes de cartelera de Quito
(busca cada una para la fecha de HOY y cruza la información):
- Plataformas de venta de entradas: TicketShow (ticketshow.com.ec),
  Conciertos Ecuador, Quito Eventos, PrimeBox / primeboxtickets,
  Ticketmaster Ecuador, Eventbrite Quito, Feria Ticket, Joinnus.
- Agendas culturales: agenda del Municipio de Quito / Quito Cultura,
  Fundación Teatro Nacional Sucre, Casa de la Cultura Ecuatoriana,
  carteleras de prensa local (El Comercio, El Universo, Metro Ecuador,
  Primicias) y redes sociales de los recintos.
- Recintos típicos donde mirar la cartelera del día: Plaza de Toros /
  Plaza de Toros Quito (Belmonte/Iñaquito), Teatro Nacional Sucre,
  Teatro San Gabriel, Teatro Bolívar, Teatro México, Ágora Casa de la
  Cultura, Teatro Nacional CCE, Coliseo General Rumiñahui, Estadio
  Olímpico Atahualpa, Estadio Rodrigo Paz Delgado (Casa Blanca, LDU),
  Centro de Convenciones Metropolitano / Quorum (Cumbayá).

Estas categorías y venues son referencia (la lista NO es exhaustiva). Incluye
un evento solo si concentra público masivo y genera demanda de taxi; descarta
lo administrativo o sin aglomeración aunque ocurra en estos lugares:

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
- NO inventes ni fuerces eventos. Incluye SOLO eventos reales y confirmables
  para la fecha indicada (HOY, ${dateLabel}). Si no puedes confirmar que el
  evento es HOY, NO lo incluyas: no uses la fecha de HOY como estimación para
  eventos de fecha dudosa.
- Si un campo concreto (hora exacta, coordenadas, etc.) no lo sabes con
  certeza, usa null en ESE campo; no descartes un evento real y confirmado
  para HOY solo por un dato faltante.
- Si un evento es recurrente (ferias semanales, etc.), inclúyelo solo si HOY
  corresponde y concentra público masivo.
- Incluye solo eventos confirmados con fuente verificable.
- Es válido y PREFERIBLE devolver {"events":[]} cuando HOY no hay eventos de
  aglomeración. No rellenes la lista con eventos administrativos, sin público
  masivo o de fecha dudosa con tal de no devolver vacío.
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
  // saturado (503), caemos a 2.0-flash que suele tener menos demanda.
  const models = ["gemini-2.5-flash", "gemini-2.0-flash"];
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

  // Push a TODA la cooperativa (conductores + admins + operadoras) cuando hay
  // eventos. Si no hay eventos no se notifica (no spamear "hoy no hay nada").
  let notified = 0;
  if (events.length > 0) {
    const names = events
      .map((e) => e && e.name)
      .filter((n) => typeof n === "string" && n.length > 0)
      .slice(0, 3);
    const title =
      events.length === 1
        ? "Evento hoy en Quito"
        : `${events.length} eventos hoy en Quito`;
    let body = names.join(" · ");
    if (events.length > names.length && body) body += " y más…";
    if (!body) body = "Hay eventos con demanda de taxi hoy. Toca para ver.";
    try {
      notified = await _sendFcmGlobalToRoles(
        ["conductor", "admin", "operadora"],
        { title, body },
        { type: "quito_events", date: dateKey },
      );
      console.log(
        `fetchQuitoEvents: push de eventos enviado a ${notified} dispositivos`,
      );
    } catch (e) {
      console.warn(`fetchQuitoEvents: error enviando push: ${e.message}`);
    }
  }

  return { ok: true, dateKey, count: events.length, notified };
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
        .where("status", "in", ["active", "paymentPending"]);
      if (n.audience === "drivers") {
        usersQuery = usersQuery.where("role", "==", "conductor");
      } else if (n.audience === "operadoras") {
        usersQuery = usersQuery.where("role", "==", "operadora");
      }
      const usersSnap = await usersQuery.select("fcmToken").get();
      const entries = [];
      for (const u of usersSnap.docs) {
        const fcm = u.data().fcmToken;
        if (typeof fcm === "string" && fcm.length > 0) entries.push({ token: fcm, ref: u.ref });
      }
      if (entries.length > 0) {
        const { sent, pruned } = await _sendMulticastAndPrune(entries, {
          notification: { title: n.title || "Aviso", body: n.body || "" },
          data: { type: "admin_notification", notifId: d.id },
          android: {
            priority: "high",
            notification: {
              sound: "default",
              channelId: "taxi_default",
              defaultSound: true,
              defaultVibrateTimings: true,
            },
          },
          apns: {
            payload: { aps: { sound: "default" } },
          },
        });
        console.log(`[dispatchNotif] ${d.id} sent=${sent} pruned=${pruned} tokens=${entries.length}`);
      }
      // TTL 72h: si el creador no seteó expiresAt, lo derivamos aquí
      // como now + 72h. Después purgeExpiredNotifications borra el doc.
      const update = {
        status: "dispatched",
        dispatchedAt: FieldValue.serverTimestamp(),
        recipientsCount: entries.length,
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

// ───────────────────────────────────────────────────────────────────
//  purgeOldChannelMessages — cron cada hora.
//  Borra los mensajes del CANAL (colección top-level `messages`, chat del
//  walkie-talkie) con más de 24h por `createdAt`. Incluye los mensajes de
//  voz del respaldo de radio (type:'voz' con audioUrl). Mantiene el chat del
//  canal efímero (24h) y evita docs huérfanos cuyo .wav ya borró el bot.
//  Los .wav en Oracle los borra el propio bot grabador (retención 24h).
// ───────────────────────────────────────────────────────────────────
async function _runPurgeOldChannelMessages() {
  const cutoff = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
  let deleted = 0;
  // Borrado por lotes hasta agotar los expirados.
  for (let i = 0; i < 50; i++) {
    const snap = await db
      .collection("messages")
      .where("createdAt", "<=", cutoff)
      .limit(300)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    deleted += snap.size;
    if (snap.size < 300) break;
  }
  return { deleted };
}

exports.purgeOldChannelMessages = onSchedule(
  {
    schedule: "20 * * * *", // cada hora en el minuto 20 (desfasado del otro purge)
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runPurgeOldChannelMessages();
    console.log("purgeOldChannelMessages:", JSON.stringify(summary));
    return summary;
  }
);

// ───────────────────────────────────────────────────────────────────
//  purgeOldGroupChat — cron cada hora.
//  Borra los mensajes del CHAT GRUPAL de cada asociación
//  (collectionGroup `groupMessages` bajo associationChats/{aid}/) con más
//  de 24h por `createdAt`. Mantiene el chat del grupo efímero (24h).
//  Clon de _runPurgeOldChannelMessages usando collectionGroup.
// ───────────────────────────────────────────────────────────────────
async function _runPurgeOldGroupChat() {
  const cutoff = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
  let deleted = 0;
  for (let i = 0; i < 50; i++) {
    const snap = await db
      .collectionGroup("groupMessages")
      .where("createdAt", "<=", cutoff)
      .limit(300)
      .get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((d) => batch.delete(d.ref));
    await batch.commit();
    deleted += snap.size;
    if (snap.size < 300) break;
  }
  return { deleted };
}

exports.purgeOldGroupChat = onSchedule(
  {
    schedule: "40 * * * *", // cada hora, minuto 40 (desfasado de los otros purges)
    timeZone: "America/Guayaquil",
    timeoutSeconds: 540,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runPurgeOldGroupChat();
    console.log("purgeOldGroupChat:", JSON.stringify(summary));
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
//  Cron cada 3 minutos. Threshold: 6 minutos sin updatedAt (STALE_MINUTES).
// ───────────────────────────────────────────────────────────────────

// 6 min: debe ser MAYOR que el heartbeat estacionario de la app (2 min) con
// margen para jitter de background/doze. Antes era 3 min, lo que apagaba
// falsamente a conductores quietos (estacionados) cuyo heartbeat es de minutos.
const STALE_MINUTES = 6;

async function _runMarkStaleDriversOffline() {
  const cutoffMs = Date.now() - STALE_MINUTES * 60 * 1000;
  const cutoff = Timestamp.fromMillis(cutoffMs);

  const snap = await db
    .collection("drivers")
    .where("isActive", "==", true)
    .where("updatedAt", "<", cutoff)
    .select("updatedAt")
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
        // 'desconectado' = constante que usa la app (statusOffline). Antes
        // ponía 'offline' (inconsistente con el filtro del mapa).
        status: "desconectado",
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
    schedule: "*/3 * * * *",
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

// ───────────────────────────────────────────────────────────────────
//  computeDriverPercentiles — ranking de conductores por asociación.
//  Para cada asociación, ordena los conductores por `totalTrips` y
//  escribe en CADA driver: tripsRank (1=más carreras), tripsTotalDrivers,
//  tripsTopPercent (rank/total*100 → "estás en el top X%"). El conductor
//  lee SOLO su propio doc → ve su posición sin exponer datos de otros.
//  Diario 00:45 EC. Idempotente (sobrescribe).
// ───────────────────────────────────────────────────────────────────
async function _runComputeDriverPercentiles() {
  // .select() recorta egress/RAM: los driver docs traen posición, historial,
  // etc. — aquí solo necesitamos estos 4 campos.
  const snap = await db
    .collection("drivers")
    .select("totalTrips", "associationId", "archivedAt", "deletedAt")
    .get();
  // Agrupar por asociación.
  const byAssoc = {};
  for (const d of snap.docs) {
    const data = d.data();
    if (data.archivedAt || data.deletedAt) continue;
    const aid = data.associationId;
    if (!aid) continue;
    (byAssoc[aid] = byAssoc[aid] || []).push({
      ref: d.ref,
      trips: Number(data.totalTrips) || 0,
    });
  }
  let writes = 0;
  for (const aid of Object.keys(byAssoc)) {
    const list = byAssoc[aid];
    // Orden descendente por carreras (más carreras = rank 1).
    list.sort((a, b) => b.trips - a.trips);
    const total = list.length;
    // Trocear cada 450 escrituras: un batch de Firestore admite máx 500
    // operaciones, así que una asociación con >500 conductores reventaría
    // el commit sin esto (bug latente a escala).
    let batch = db.batch();
    let n = 0;
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      const rank = i + 1;
      const topPercent = Math.max(1, Math.ceil((rank / total) * 100));
      batch.set(
        item.ref,
        {
          tripsRank: rank,
          tripsTotalDrivers: total,
          tripsTopPercent: topPercent,
          percentileUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      writes++;
      if (++n === 450) {
        await batch.commit();
        batch = db.batch();
        n = 0;
      }
    }
    if (n > 0) await batch.commit();
  }
  return { ok: true, associations: Object.keys(byAssoc).length, writes };
}

exports.computeDriverPercentiles = onSchedule(
  {
    schedule: "45 0 * * *", // 00:45 America/Guayaquil
    timeZone: "America/Guayaquil",
    timeoutSeconds: 120,
    memory: "256MiB",
    retryCount: 1,
  },
  async () => {
    const summary = await _runComputeDriverPercentiles();
    console.log("computeDriverPercentiles:", JSON.stringify(summary));
    return summary;
  },
);

exports.computeDriverPercentilesNow = onCall({}, async (request) => {
  requireSuperAdmin(request);
  return _runComputeDriverPercentiles();
});

// ───────────────────────────────────────────────────────────────────
//  onTripFinalized — al finalizar una carrera, sumar totales y
//  propagar el estado al pedido (tripRequest) para que el cliente web
//  pueda calificar.
//
//  Trigger: update de trips/{tripId}.
//  Idempotencia: solo actúa en la TRANSICIÓN a finalizado
//  (before NO finalizado && after SÍ finalizado). Re-escrituras de un
//  trip que ya estaba finalizado no vuelven a contar.
//
//  Contrato de datos (totales = SOLO cantidad de carreras, no montos):
//    - drivers/{driverId}.totalTrips += 1
//    - associations/{associationId}.totalTrips += 1  (total de la base)
//    - tripStatsDaily/{associationId}_{YYYY-MM-DD} → agregado diario por
//      asociación: carreras por hora, total y estimado monetario (UTC-5)
//    - tripRequests/{tripRequestId} → estado:'finalizada', finalizadoAt
// ───────────────────────────────────────────────────────────────────

// Resuelve la REFERENCIA al doc de un conductor a partir de su UID de auth.
// IMPORTANTE: en este proyecto los docs de `drivers/` tienen id AUTO-generado
// y guardan el uid en el campo `userId` (así los crea approveDriver/.add() y
// los resuelve DriverLocationService). `trips.driverId` y `tripRequests.driverId`
// son el UID del usuario, NO el id del doc. Por eso buscamos por `userId`.
// Fallback: algún doc legacy podría tener id == uid (código que usa .doc(uid)).
async function resolveDriverRef(driverUid) {
  if (!driverUid) return null;
  const q = await db
    .collection("drivers")
    .where("userId", "==", driverUid)
    .limit(1)
    .get();
  if (!q.empty) return q.docs[0].ref;
  const direct = db.collection("drivers").doc(driverUid);
  const snap = await direct.get();
  return snap.exists ? direct : null;
}

// Deriva el epoch (ms UTC) del momento de la carrera para el agregado
// diario. Preferimos `createdAt`; si falta, `finalizadoAt`; y por último
// la hora actual. Acepta Timestamp de Firestore (.toMillis()), Date,
// número de epoch (ms) o segundos (campo {seconds}).
function resolveTripEpochMs(after) {
  const candidates = [after?.createdAt, after?.finalizadoAt];
  for (const c of candidates) {
    if (!c) continue;
    if (typeof c.toMillis === "function") return c.toMillis(); // Timestamp
    if (c instanceof Date) return c.getTime();
    if (typeof c === "number") return c; // epoch ms
    if (typeof c.seconds === "number") return c.seconds * 1000; // {seconds,...}
  }
  return Date.now();
}

// ───────────────────────────────────────────────────────────────────
//  onTripRequestCreated — push a operadoras + admins cuando entra una
//  nueva solicitud de carrera desde el portal web del cliente.
//
//  Trigger: create de tripRequests/{reqId}. La crea el portal web con
//  estado='pendiente' (ver client_web/.../home/page.tsx). Solo avisamos
//  para solicitudes nuevas en estado 'pendiente'.
// ───────────────────────────────────────────────────────────────────
// Helper: incrementa un contador del embudo de solicitudes web en el
// agregado diario `tripRequestStatsDaily/{aid}_{date}`. La fecha es la de
// la SOLICITUD (cohorte): así el embudo de un día refleja cuántas de las
// solicitudes recibidas ese día terminaron asignadas/finalizadas/canceladas.
async function _incrTripRequestStat(aid, epochMs, field) {
  if (!aid) return;
  try {
    const { date, dayOfWeek } = localDateHourEC(epochMs);
    const statsId = `${aid}_${date}`;
    const dateTs = Timestamp.fromMillis(Date.parse(`${date}T05:00:00.000Z`));
    await db
      .collection("tripRequestStatsDaily")
      .doc(statsId)
      .set(
        {
          associationId: aid,
          date,
          dateTs,
          dayOfWeek,
          [field]: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
  } catch (e) {
    console.warn(`[tripRequestStats] no pude incrementar ${field}: ${e.message}`);
  }
}

exports.onTripRequestCreated = onDocumentCreated(
  { document: "tripRequests/{reqId}", region: "us-central1" },
  async (event) => {
    const req = event.data?.data();
    if (!req) return;
    if (req.estado && req.estado !== "pendiente") return;
    const aid = req.associationId;
    if (!aid) {
      console.warn(
        `[onTripRequestCreated] req ${event.params.reqId} sin associationId; omito push.`,
      );
      return;
    }
    // Embudo: +1 recibida en la fecha de la solicitud.
    await _incrTripRequestStat(aid, resolveTripEpochMs(req), "recibidas");
    const cliente = req.clienteNombre || "Cliente";
    const origen = req.origen?.address || req.destinoTexto || "";
    try {
      const n = await _sendFcmToRoles(
        aid,
        ["operadora", "admin"],
        {
          title: "Nueva solicitud de carrera",
          body: origen ? `${cliente} · ${origen}` : cliente,
        },
        { type: "trip_request", reqId: event.params.reqId },
      );
      console.log(
        `[onTripRequestCreated] req ${event.params.reqId} (${aid}) → push a ${n} operadoras/admins`,
      );
    } catch (e) {
      console.warn(
        `[onTripRequestCreated] error enviando push: ${e.message}`,
      );
    }
  },
);

// ───────────────────────────────────────────────────────────────────
//  onGroupMessageCreated — push FCM a TODOS los miembros activos de la
//  asociación (menos el emisor) cuando entra un mensaje al chat grupal.
//
//  Trigger: create de associationChats/{aid}/groupMessages/{msgId}.
//  Reusa la lógica pura testeada (buildNotification / tokensForAssociation)
//  y el helper _sendMulticastAndPrune (envía en lotes de 500 + borra tokens
//  muertos). Para poder podar tokens muertos construimos `entries`
//  (token+ref) en el trigger con la MISMA lógica de filtrado que
//  tokensForAssociation; esa función pura se mantiene intacta para el test.
// ───────────────────────────────────────────────────────────────────
// Cache simple de nombres de asociación (como en el bot recorder).
const _assocNames = new Map();
const _ASSOC_NAMES_MAX = 500;
async function _getAssociationName(aid) {
  if (_assocNames.has(aid)) {
    // Refresca posición LRU: re-insertar lo deja como más reciente.
    const v = _assocNames.get(aid);
    _assocNames.delete(aid);
    _assocNames.set(aid, v);
    return v;
  }
  let name = aid;
  try {
    // Nota: .select() solo existe en Query/CollectionReference, no en
    // DocumentReference, así que aquí el get() trae el doc completo. El doc
    // de associations es chico y se cachea (LRU abajo), así que no vale la
    // pena reescribirlo como query por documentId solo para proyectar `name`.
    const snap = await db.collection("associations").doc(aid).get();
    if (snap.exists) name = snap.data().name || aid;
  } catch (_) { /* noop */ }
  if (_assocNames.size >= _ASSOC_NAMES_MAX) {
    // Evict el más viejo (primera clave en orden de inserción).
    _assocNames.delete(_assocNames.keys().next().value);
  }
  _assocNames.set(aid, name);
  return name;
}

exports.onGroupMessageCreated = onDocumentCreated(
  { document: "associationChats/{aid}/groupMessages/{msgId}", region: "us-central1" },
  async (event) => {
    const msg = event.data?.data();
    if (!msg) return;
    const aid = event.params.aid;
    const senderId = msg.senderId;

    // Usuarios activos de la asociación (con uid del doc).
    // tokensForAssociation re-verifica associationId y status sobre cada doc,
    // así que el .select debe incluirlos además de fcmToken (uid sale del id
    // del doc, no de un campo). status va también en el .where.
    const snap = await db
      .collection("users")
      .where("associationId", "==", aid)
      .where("status", "==", "active")
      .select("fcmToken", "associationId", "status")
      .get();

    // Construimos entries {token, ref} aplicando la misma regla que
    // tokensForAssociation (activos, con token no vacío, sin el emisor).
    // tokensForAssociation se usa como guard rápido para abortar temprano.
    const userDocs = snap.docs.map((d) => ({ uid: d.id, ...d.data() }));
    const tokens = tokensForAssociation(userDocs, aid, senderId);
    if (tokens.length === 0) return;

    const entries = [];
    for (const d of snap.docs) {
      if (d.id === senderId) continue;
      const t = d.data().fcmToken;
      if (typeof t === "string" && t.length > 0) {
        entries.push({ token: t, ref: d.ref });
      }
    }
    if (entries.length === 0) return;

    const associationName = await _getAssociationName(aid);
    const { title, body } = buildNotification({
      senderName: msg.senderName,
      text: msg.text,
      associationName,
    });

    const data = { type: "group_chat", associationId: aid };
    const { sent, pruned } = await _sendMulticastAndPrune(entries, {
      notification: { title, body },
      data,
      android: {
        priority: "high",
        notification: {
          sound: "default",
          channelId: "taxi_default",
          defaultSound: true,
          defaultVibrateTimings: true,
        },
      },
      apns: { payload: { aps: { sound: "default" } } },
    });
    console.log(
      `[group-chat] push aid=${aid} tokens=${entries.length} sent=${sent} pruned=${pruned}`,
    );
  },
);

// ───────────────────────────────────────────────────────────────────
//  onTripAssignmentChanged — push al CONDUCTOR cuando una carrera:
//   • se le ASIGNA (create de trips/{id} con driverId)
//   • se REASIGNA (update con cambio de driverId) → avisa al nuevo y al
//     anterior
//   • se CANCELA (update status → 'cancelado') → avisa al conductor
//
//  Trigger: write de trips/{tripId} (create+update). Convive con
//  onTripFinalized (onDocumentUpdated) que sigue a cargo de totales y de
//  propagar el estado al tripRequest. Aquí SOLO se envían push.
// ───────────────────────────────────────────────────────────────────
exports.onTripAssignmentChanged = onDocumentWritten(
  { document: "trips/{tripId}", region: "us-central1" },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!after) return; // borrado → nada
    const tripId = event.params.tripId;
    const cliente = after.clienteNombre || "Cliente";
    const origen = after.pickupAddress || "";
    const bodyAsignada = origen ? `${cliente} · ${origen}` : cliente;

    // CREATE → asignación inicial.
    if (!before) {
      if (after.driverId && after.status !== "cancelado") {
        await _sendFcmToUid(
          after.driverId,
          { title: "Carrera asignada", body: bodyAsignada },
          { type: "trip_assigned", tripId },
        ).catch((e) =>
          console.warn(`[onTripAssignmentChanged] asignación: ${e.message}`),
        );
        console.log(
          `[onTripAssignmentChanged] trip ${tripId} asignado → push a ${after.driverId}`,
        );
      }
      return;
    }

    // UPDATE → cancelación (transición a cancelado).
    if (before.status !== "cancelado" && after.status === "cancelado") {
      const target = after.driverId || before.driverId;
      if (target) {
        await _sendFcmToUid(
          target,
          { title: "Carrera cancelada", body: bodyAsignada },
          { type: "trip_cancelled", tripId },
        ).catch((e) =>
          console.warn(`[onTripAssignmentChanged] cancelación: ${e.message}`),
        );
        console.log(
          `[onTripAssignmentChanged] trip ${tripId} cancelado → push a ${target}`,
        );
      }
      return;
    }

    // UPDATE → reasignación (cambió el conductor).
    if (
      before.driverId &&
      after.driverId &&
      before.driverId !== after.driverId
    ) {
      await _sendFcmToUid(
        after.driverId,
        { title: "Carrera asignada", body: bodyAsignada },
        { type: "trip_assigned", tripId },
      ).catch((e) =>
        console.warn(`[onTripAssignmentChanged] reasign nuevo: ${e.message}`),
      );
      await _sendFcmToUid(
        before.driverId,
        {
          title: "Carrera reasignada",
          body: "Esta carrera se asignó a otra unidad.",
        },
        { type: "trip_reassigned_away", tripId },
      ).catch((e) =>
        console.warn(`[onTripAssignmentChanged] reasign previo: ${e.message}`),
      );
      console.log(
        `[onTripAssignmentChanged] trip ${tripId} reasignado ${before.driverId} → ${after.driverId}`,
      );
    }
  },
);

exports.onTripFinalized = onDocumentUpdated(
  {
    document: "trips/{tripId}",
    region: "us-central1",
  },
  async (event) => {
    const tripId = event.params.tripId;
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();

    // Sin datos (borrado) → nada que hacer.
    if (!after) return;

    // Propagación de CANCELACIÓN al pedido web. Robustez extra: aunque el
    // cliente Flutter ya intenta poner el tripRequest en 'cancelada' al
    // cancelar, lo hacemos también server-side por si esa escritura falla o
    // el cancel vino de otra ruta. Solo en la transición a 'cancelado'.
    if (before?.status !== "cancelado" && after.status === "cancelado") {
      if (after.tripRequestId) {
        try {
          await db.collection("tripRequests").doc(after.tripRequestId).update({
            estado: "cancelada",
            updatedAt: FieldValue.serverTimestamp(),
          });
          console.log(
            `[onTripFinalized] trip ${tripId} cancelado → tripRequest ${after.tripRequestId} = cancelada`,
          );
        } catch (e) {
          console.warn(
            `[onTripFinalized] no pude propagar cancelación a ` +
              `tripRequest ${after.tripRequestId}: ${e.message}`,
          );
        }
      }
      return; // cancelar NO suma totales ni agregados.
    }

    // Sin transición a finalizado → nada más que hacer.
    if (!isTransitionToFinalized(before?.status, after.status)) {
      return;
    }

    const driverId = after.driverId || null;
    // Resolvemos el doc real del conductor (id auto, ubicado por userId).
    const driverRef = await resolveDriverRef(driverId);

    // 1) Incrementar totalTrips del conductor (si lo encontramos).
    if (driverRef) {
      try {
        await driverRef.update({
          totalTrips: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        });
        console.log(
          `[onTripFinalized] trip ${tripId}: +1 totalTrips a driver ${driverId} (doc ${driverRef.id})`,
        );
      } catch (e) {
        // Si el doc del driver no existe, no rompemos el resto del flujo.
        console.warn(
          `[onTripFinalized] no pude incrementar driver ${driverId}: ${e.message}`,
        );
      }
    } else {
      console.log(
        `[onTripFinalized] trip ${tripId} sin driver doc (driverId=${driverId}); no cuento al conductor.`,
      );
    }

    // 2) Incrementar totalTrips de la asociación (total de la base).
    //    Si el trip no trae associationId (docs viejos), lo derivamos del
    //    driver y, en su defecto, del tripRequest. Si aun así no hay,
    //    logueamos y omitimos el total de base.
    let aid = after.associationId || null;
    if (!aid && driverRef) {
      try {
        const dSnap = await driverRef.get();
        if (dSnap.exists) aid = dSnap.data().associationId || null;
      } catch (_) { /* noop */ }
    }
    if (!aid && after.tripRequestId) {
      try {
        const reqSnap = await db
          .collection("tripRequests")
          .doc(after.tripRequestId)
          .get();
        if (reqSnap.exists) aid = reqSnap.data().associationId || null;
      } catch (_) { /* noop */ }
    }
    if (aid) {
      try {
        await db.collection("associations").doc(aid).update({
          totalTrips: FieldValue.increment(1),
          updatedAt: FieldValue.serverTimestamp(),
        });
        console.log(
          `[onTripFinalized] trip ${tripId}: +1 totalTrips a association ${aid}`,
        );
      } catch (e) {
        console.warn(
          `[onTripFinalized] no pude incrementar association ${aid}: ${e.message}`,
        );
      }
    } else {
      console.log(
        `[onTripFinalized] trip ${tripId} sin associationId derivable; omito total de base.`,
      );
    }

    // 2b) Mantener el AGREGADO DIARIO por asociación (tripStatsDaily).
    //     Permite que el reporte del CONDUCTOR compare contra "la base"
    //     (carreras por hora + estimado monetario) sin leer carreras
    //     ajenas. Solo corre en la transición a finalizado, así que cada
    //     carrera se cuenta exactamente una vez (idempotencia heredada).
    //
    //     Fecha/hora en zona America/Guayaquil (UTC-5). Tomamos el momento
    //     de la carrera de `after.createdAt`; si falta, `after.finalizadoAt`;
    //     y como último recurso la hora actual. Soportamos tanto Timestamp
    //     de Firestore (con .toMillis()) como número de epoch.
    if (aid) {
      try {
        const epochMs = resolveTripEpochMs(after);
        const { date, hour, dayOfWeek } = localDateHourEC(epochMs);
        const fare = fareForHour(hour);
        const statsId = `${aid}_${date}`;
        // Inicio del día en UTC-5 → 00:00 local = 05:00 UTC del mismo día.
        // Lo guardamos como Timestamp para poder hacer range queries por fecha.
        const dateTs = Timestamp.fromMillis(Date.parse(`${date}T05:00:00.000Z`));

        // OJO: en el Admin SDK, una clave con punto dentro de set() se toma
        // LITERAL (no como ruta anidada). Para incrementar el bucket de la
        // hora dentro del map `tripsByHour` anidamos el objeto: { [hour]: inc }.
        // Con {merge:true} esto sólo toca esa hora, sin pisar las demás.
        await db
          .collection("tripStatsDaily")
          .doc(statsId)
          .set(
            {
              associationId: aid,
              date,
              dateTs,
              // dayOfWeek (0=dom..6=sáb, hora local EC): para heatmap DoW×hora
              // y comparativas "lunes vs lunes" sin recalcular en cliente.
              dayOfWeek,
              tripsByHour: { [String(hour)]: FieldValue.increment(1) },
              totalTrips: FieldValue.increment(1),
              estimatedRevenue: FieldValue.increment(fare),
              updatedAt: FieldValue.serverTimestamp(),
            },
            { merge: true },
          );
        console.log(
          `[onTripFinalized] trip ${tripId}: agregado diario ${statsId} ` +
            `(hora ${hour}, +${fare} estimado).`,
        );

        // Agregado diario POR CONDUCTOR (driverStatsDaily): mismo esquema que
        // el de base, pero por driverId. Habilita el reporte personal del
        // conductor (sus carreras, sus horas pico, su estimado) y métricas de
        // productividad por conductor. driverId aquí es el UID del usuario.
        if (driverId) {
          const dStatsId = `${driverId}_${date}`;
          await db
            .collection("driverStatsDaily")
            .doc(dStatsId)
            .set(
              {
                driverId,
                associationId: aid,
                date,
                dateTs,
                dayOfWeek,
                tripsByHour: { [String(hour)]: FieldValue.increment(1) },
                totalTrips: FieldValue.increment(1),
                estimatedRevenue: FieldValue.increment(fare),
                updatedAt: FieldValue.serverTimestamp(),
              },
              { merge: true },
            );
          console.log(
            `[onTripFinalized] trip ${tripId}: agregado diario conductor ${dStatsId}.`,
          );
        }
      } catch (e) {
        console.warn(
          `[onTripFinalized] no pude actualizar agregado diario de ` +
            `association ${aid}: ${e.message}`,
        );
      }
    } else {
      console.log(
        `[onTripFinalized] trip ${tripId} sin associationId; omito agregado diario.`,
      );
    }

    // 3) Propagar al pedido para que el cliente web vea "finalizada" y
    //    pueda calificar. finalizadoAt: usamos el del trip si existe,
    //    si no serverTimestamp.
    if (after.tripRequestId) {
      try {
        await db.collection("tripRequests").doc(after.tripRequestId).update({
          estado: "finalizada",
          finalizadoAt: after.finalizadoAt || FieldValue.serverTimestamp(),
          tripId,
          updatedAt: FieldValue.serverTimestamp(),
        });
        console.log(
          `[onTripFinalized] tripRequest ${after.tripRequestId} → finalizada`,
        );
      } catch (e) {
        console.warn(
          `[onTripFinalized] no pude actualizar tripRequest ` +
            `${after.tripRequestId}: ${e.message}`,
        );
      }
    }
  },
);

// ───────────────────────────────────────────────────────────────────
//  onTripRequestStatusChanged — embudo de solicitudes web (calidad de
//  servicio). Cuenta las transiciones de estado de cada solicitud en el
//  agregado diario por COHORTE (fecha de la solicitud), para medir, de
//  las recibidas un día, cuántas se asignaron / finalizaron / cancelaron.
//  Trigger: update de tripRequests/{reqId}. Idempotente por flanco.
// ───────────────────────────────────────────────────────────────────
exports.onTripRequestStatusChanged = onDocumentUpdated(
  { document: "tripRequests/{reqId}", region: "us-central1" },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();
    if (!after) return;
    const aid = after.associationId;
    if (!aid) return;
    const b = before?.estado;
    const a = after.estado;
    if (b === a) return; // sin cambio de estado
    const epochMs = resolveTripEpochMs(after); // cohorte = fecha solicitud
    if (b !== "asignada" && a === "asignada") {
      await _incrTripRequestStat(aid, epochMs, "asignadas");
    } else if (b !== "finalizada" && a === "finalizada") {
      await _incrTripRequestStat(aid, epochMs, "finalizadas");
    } else if (b !== "cancelada" && a === "cancelada") {
      await _incrTripRequestStat(aid, epochMs, "canceladas");
    }
  },
);

// ───────────────────────────────────────────────────────────────────
//  onTripRequestRated — al calificar el cliente, actualizar el
//  promedio del conductor.
//
//  Trigger: update de tripRequests/{reqId}.
//  Idempotencia: solo cuenta la PRIMERA vez que aparece la calificación
//  (before sin rating válido && after rating entero 1..5). Si el cliente
//  edita la calificación luego, NO se recuenta (evita inflar el promedio).
//
//  Acción (en transacción para leer-modificar-escribir de forma atómica):
//    drivers/{after.driverId}:
//      ratingSum   += after.rating
//      ratingCount += 1
//      rating       = ratingSum / ratingCount
//    Inicializa ratingSum/ratingCount en 0 si el driver es nuevo.
// ───────────────────────────────────────────────────────────────────

exports.onTripRequestRated = onDocumentUpdated(
  {
    document: "tripRequests/{reqId}",
    region: "us-central1",
  },
  async (event) => {
    const reqId = event.params.reqId;
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();

    if (!after) return;
    if (!isFirstRating(before?.rating, after.rating)) {
      return;
    }

    const driverId = after.driverId || null;
    if (!driverId) {
      console.log(
        `[onTripRequestRated] tripRequest ${reqId} sin driverId; omito.`,
      );
      return;
    }

    const newRating = after.rating;
    // El doc de drivers tiene id auto; lo ubicamos por userId (resolvemos
    // FUERA de la transacción porque runTransaction no admite queries dentro).
    const driverRef = await resolveDriverRef(driverId);
    if (!driverRef) {
      console.warn(
        `[onTripRequestRated] tripRequest ${reqId}: no encontré driver doc ` +
          `para uid ${driverId}; omito el promedio.`,
      );
      return;
    }

    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(driverRef);
        const current = snap.exists ? snap.data() : {};
        const { ratingSum, ratingCount, rating } = computeNewAverage(
          current,
          newRating,
        );
        // Si el doc no existe lo dejamos pasar a update (fallaría); por eso
        // usamos set con merge para inicializar acumuladores en driver nuevo.
        tx.set(
          driverRef,
          {
            ratingSum,
            ratingCount,
            rating,
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      });
      console.log(
        `[onTripRequestRated] tripRequest ${reqId}: rating ${newRating} ` +
          `aplicado a driver ${driverId}`,
      );
    } catch (e) {
      console.error(
        `[onTripRequestRated] falló transacción para driver ${driverId}: ` +
          `${e.message}`,
      );
    }
  },
);

// ───────────────────────────────────────────────────────────────────
//  backfillNextDueAt — callable de UNA SOLA VEZ (super-admin).
//  Puebla nextDueAt / lastValidatedPaymentAt / dueComputeVersion en los
//  conductores existentes. Por diseño es SEGURO:
//   - Por defecto corre en DRY-RUN: NO escribe nada, solo cuenta y muestra
//     ejemplos. Solo escribe si se invoca con { dryRun: false } explícito.
//   - En modo real es ADITIVO: escribe campos nuevos con merge:true y NUNCA
//     toca `status` (no bloquea a nadie por sí mismo).
//   - El N+1 (_lastValidatedPayment por conductor) es aceptable porque esto
//     corre una sola vez.
//  Devuelve un resumen con `wouldBlock` (cuántos quedarían vencidos AHORA)
//  para compararlo contra `blockedCuota` (los que el sistema viejo tiene
//  bloqueados por cuota). Si wouldBlock ≫ blockedCuota hay un error de
//  cómputo → no se debe ejecutar el real.
// ───────────────────────────────────────────────────────────────────

exports.backfillNextDueAt = onCall({ timeoutSeconds: 540 }, async (request) => {
  requireSuperAdmin(request);
  // Default DRY-RUN (seguro): solo escribe si dryRun:false explícito.
  const dryRun = request.data?.dryRun !== false;
  const now = Timestamp.now();

  let scanned = 0, withDue = 0, wouldBlock = 0, written = 0, assocCount = 0;
  const samples = []; // hasta ~20 ejemplos para inspección

  // Asociaciones con cobro activo (billingConfig.amount > 0).
  const assocSnap = await db.collection("associations").get();
  for (const a of assocSnap.docs) {
    const cfg = a.data().billingConfig;
    if (!cfg || !(Number(cfg.amount) > 0)) continue;
    assocCount++;

    const usersSnap = await db.collection("users")
      .where("associationId", "==", a.id)
      .where("role", "in", ["conductor", "admin"])
      .select("approvedAt") // solo lo necesario
      .get();

    let batch = db.batch();
    let n = 0;
    for (const u of usersSnap.docs) {
      scanned++;
      const approvedAt = u.data().approvedAt;
      let nextDueAt = null;
      let lastValidatedAt = null;
      if (approvedAt) {
        // N+1 SOLO en este backfill de una vez.
        const last = await _lastValidatedPayment(u.id, a.id);
        lastValidatedAt = (last && last.validatedAt) ? last.validatedAt : null;
        const d = computeNextDueAtForUser({
          approvedAt: approvedAt.toDate ? approvedAt.toDate() : approvedAt,
          lastPayment: last ? { validatedAt: last.validatedAt } : null,
          billingConfig: cfg,
        });
        nextDueAt = d ? Timestamp.fromDate(d) : null;
      }

      const isOverdue = !!(nextDueAt && nextDueAt.toMillis() <= now.toMillis());
      if (nextDueAt) {
        withDue++;
        if (isOverdue) wouldBlock++;
      }
      if (samples.length < 20) {
        samples.push({
          uid: u.id,
          aid: a.id,
          nextDueAt: nextDueAt ? nextDueAt.toDate().toISOString() : null,
          wouldBlock: isOverdue,
        });
      }

      if (!dryRun) {
        batch.set(
          u.ref,
          {
            nextDueAt,
            lastValidatedPaymentAt: lastValidatedAt,
            dueComputeVersion: 1,
          },
          { merge: true }
        );
        written++;
        if (++n === 450) {
          await batch.commit();
          batch = db.batch();
          n = 0;
        }
      }
    }
    if (!dryRun && n > 0) await batch.commit();
  }

  // Para comparar: cuántos están HOY bloqueados por cuota en el sistema viejo.
  const blockedSnap = await db.collection("users")
    .where("status", "==", "paymentBlocked")
    .select("blockReason")
    .get();
  let blockedNow = 0, blockedCuota = 0;
  blockedSnap.forEach((d) => {
    blockedNow++;
    if (d.data().blockReason === "cuota_vencida") blockedCuota++;
  });

  const summary = {
    dryRun,
    associations: assocCount,
    scanned,
    withDue,
    wouldBlock,
    written,
    blockedNow,
    blockedCuota,
    samples,
  };
  console.log(
    "backfillNextDueAt:",
    JSON.stringify({ ...summary, samples: samples.length })
  );
  return summary;
});

