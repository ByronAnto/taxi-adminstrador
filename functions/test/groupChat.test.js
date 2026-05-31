// functions/test/groupChat.test.js
const { buildNotification, tokensForAssociation } = require('../lib/groupChat');

describe('buildNotification', () => {
  test('arma título con nombre de asociación y trunca el cuerpo', () => {
    const long = 'a'.repeat(200);
    const n = buildNotification({
      senderName: 'Byron', text: long, associationName: 'Jipijapa',
    });
    expect(n.title).toBe('Grupo · Jipijapa');
    expect(n.body.length).toBeLessThanOrEqual(123); // 120 + '...'
    expect(n.body.endsWith('...')).toBe(true);
  });
  test('cuerpo corto no se trunca', () => {
    const n = buildNotification({
      senderName: 'Byron', text: 'hola', associationName: 'Jipijapa',
    });
    expect(n.body).toBe('Byron: hola');
  });
});

describe('tokensForAssociation', () => {
  const users = [
    { associationId: 'a', status: 'active', fcmToken: 't1' },
    { associationId: 'a', status: 'active', fcmToken: 't2' }, // emisor
    { associationId: 'a', status: 'inactive', fcmToken: 't3' },
    { associationId: 'b', status: 'active', fcmToken: 't4' },
    { associationId: 'a', status: 'active', fcmToken: '' },
  ];
  test('solo activos de la asociación, sin el emisor ni tokens vacíos', () => {
    const toks = tokensForAssociation(users, 'a', 'u2', { 't2': 'u2' });
    expect(toks).toEqual(['t1']);
  });
});
