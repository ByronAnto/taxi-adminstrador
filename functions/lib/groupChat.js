// functions/lib/groupChat.js
'use strict';

const BODY_MAX = 120;

/// Arma {title, body} de la push del grupo. Trunca el texto a BODY_MAX.
function buildNotification({ senderName, text, associationName }) {
  const name = (associationName || '').trim() || 'Asociación';
  const sender = (senderName || '').trim() || 'Alguien';
  let body = `${sender}: ${text || ''}`;
  if (body.length > BODY_MAX) body = body.slice(0, BODY_MAX) + '...';
  return { title: `Grupo · ${name}`, body };
}

/// Filtra tokens FCM de los miembros ACTIVOS de la asociación `aid`, excluyendo
/// al emisor y tokens vacíos. `userDocs` es un array de objetos de usuario que
/// incluyen `{ associationId, status, fcmToken, uid? }`. Para identificar al
/// emisor cuando los docs no traen uid, se acepta un `tokenToUid` opcional.
function tokensForAssociation(userDocs, aid, senderId, tokenToUid = {}) {
  const out = [];
  for (const u of userDocs) {
    if (u.associationId !== aid) continue;
    if (u.status !== 'active') continue;
    const t = u.fcmToken;
    if (typeof t !== 'string' || t.length === 0) continue;
    const uid = u.uid != null ? u.uid : tokenToUid[t];
    if (uid === senderId) continue;
    out.push(t);
  }
  return out;
}

module.exports = { buildNotification, tokensForAssociation };
