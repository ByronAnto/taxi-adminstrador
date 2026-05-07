const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
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

  // Transferencia atómica
  await db.runTransaction(async (tx) => {
    // 1. Promover nuevo admin
    tx.update(newAdminRef, {
      role: "admin",
      updatedAt: FieldValue.serverTimestamp(),
    });

    // 2. Degradar admin saliente a "conductor"
    if (oldAdminUid && oldAdminUid !== newAdminUid) {
      const oldAdminRef = db.collection("users").doc(oldAdminUid);
      const oldAdminSnap = await tx.get(oldAdminRef);
      if (oldAdminSnap.exists) {
        tx.update(oldAdminRef, {
          role: "conductor",
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
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

  // 1) Borrar el doc de Firestore
  await userRef.delete();

  // 2) Borrar la cuenta de Firebase Auth (si aún existe)
  try {
    await getAuth().deleteUser(userUid);
  } catch (e) {
    // Si la cuenta ya no existe en Auth, no es error.
    if (e.code !== "auth/user-not-found") {
      console.warn(`deleteUser: no pude borrar Auth ${userUid}`, e);
    }
  }

  return { ok: true, deletedUid: userUid };
});

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

  if (user.status && user.status !== "active") {
    throw new HttpsError(
      "failed-precondition",
      "Tu cuenta no está activa. No puedes reportar pagos."
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

  const ref = db.collection("payments").doc();
  await ref.set({
    associationId: aid,
    driverId: auth.uid,
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

  return { ok: true };
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

    // Recorrer conductores de esta asociación.
    const driversSnap = await db
      .collection("users")
      .where("associationId", "==", aDoc.id)
      .where("role", "==", "conductor")
      .get();

    for (const uDoc of driversSnap.docs) {
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
