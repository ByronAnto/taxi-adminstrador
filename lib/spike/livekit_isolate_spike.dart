// SPIKE (THROWAWAY) — Fase 0 del plan paridad Zello.
// Objetivo: confirmar que livekit_client (WebRTC) conecta, recibe audio y deja
// el mic libre DESDE el isolate del foreground service, y sobrevive al swipe.
//
// Diseño decisivo y mínimo:
//   - MAIN (autenticado): pide el token a la Cloud Function y lo manda al handler.
//   - HANDLER (isolate FGS): hace el room.connect crudo + altavoz, sin Firebase.
//
// TODO BORRAR tras la decisión (no es código de producción).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show Helper, AndroidAudioConfiguration;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/radio_power_service.dart';

/// Señales del protocolo del spike (strings/maps que cruzan isolates).
const String kSpikeNeedToken = '[SPIKE] need-token';
const String kSpikeLogPrefix = '[SPIKE] log:';

// ─── Log HTTP DIRECTO desde el isolate del handler ───
// Escribe al mismo servidor de logs pero con user='SPIKEHANDLER' → archivo
// aparte SPIKEHANDLER-<fecha>.log. Bypassa el main y la captura por zona:
// si este archivo aparece, el handler SÍ está corriendo. http es Dart puro
// (no requiere plugins) → funciona en cualquier isolate.
const String _spikeLogEndpoint = 'https://livekit.it-services.center/logs';
const String _spikeLogToken =
    '88852143cc951681e450b18f644cd7339658f5c4cb93e721';

Future<void> spikeHttpLog(String msg) async {
  try {
    await http
        .post(
          Uri.parse(_spikeLogEndpoint),
          headers: const {
            'Authorization': 'Bearer $_spikeLogToken',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'device': 'handler-isolate',
            'user': 'SPIKEHANDLER',
            'role': 'handler',
            'ver': 'spike',
            'lines': [msg],
          }),
        )
        .timeout(const Duration(seconds: 8));
  } catch (_) {}
}

// ───────────────────────── MAIN ISOLATE ─────────────────────────

/// Corre en el isolate PRINCIPAL (autenticado). Lee el último canal de prefs,
/// pide el token a la Cloud Function y se lo envía al handler del FGS.
// Log directo del lado MAIN (lo captura RemoteLogService → /logs, sin depender
// de la cadena inter-isolate). Sirve para bisectar dónde se rompe el spike.
void _mlog(String m) => debugPrint('📻 [SPIKE-MAIN] $m');

Future<void> spikeProvideTokenToHandler() async {
  _mlog('need-token recibido en main. radioOn=${RadioPowerService.instance.isOn}');
  try {
    // GUARDA anti doble-identidad: si el radio normal está ON, el isolate
    // principal ya está conectado con esta identidad → NO conectar el spike.
    if (RadioPowerService.instance.isOn) {
      _mlog('BLOQUEADO: radio normal ON → no conecto spike');
      FlutterForegroundTask.sendDataToTask({
        'spike': 'error',
        'msg': 'radio normal ENCENDIDO',
      });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final channelId = prefs.getString('radio.power.lastChannelId');
    if (channelId == null || channelId.isEmpty) {
      _mlog('SIN lastChannelId en prefs');
      FlutterForegroundTask.sendDataToTask(
          {'spike': 'error', 'msg': 'sin lastChannelId'});
      return;
    }
    _mlog('pidiendo token CF para canal=$channelId');

    final res = await FirebaseFunctions.instance
        .httpsCallable('generateLiveKitToken')
        .call({'channelName': channelId}).timeout(const Duration(seconds: 15));
    final data = (res.data as Map?) ?? const {};
    final url = data['url'] as String?;
    final token = data['token'] as String?;
    if (url == null || token == null || url.isEmpty || token.isEmpty) {
      _mlog('token inválido de la CF');
      FlutterForegroundTask.sendDataToTask(
          {'spike': 'error', 'msg': 'token inválido'});
      return;
    }

    _mlog('token OK (${token.length} chars) → mando connect al handler');
    FlutterForegroundTask.sendDataToTask({
      'spike': 'connect',
      'url': url,
      'token': token,
      'channel': channelId,
    });
  } catch (e) {
    _mlog('EXCEPCIÓN en main: $e');
    FlutterForegroundTask.sendDataToTask({'spike': 'error', 'msg': '$e'});
  }
}

// ───────────────────────── HANDLER ISOLATE (FGS) ─────────────────────────

lk.Room? _spikeRoom;
bool _spikeBusy = false;

/// True si el spike ya tiene una Room conectada (lo usa el retry del handler
/// para dejar de reintentar).
bool spikeConnected() => _spikeRoom != null;

void _hlog(String m) => FlutterForegroundTask.sendDataToMain('$kSpikeLogPrefix $m');

/// Corre en el isolate del FGS. Conexión LiveKit cruda con el token recibido.
Future<void> spikeHandlerConnect(Map data) async {
  final kind = data['spike'];
  if (kind == 'error') {
    _hlog('main reportó error: ${data['msg']}');
    return;
  }
  if (kind != 'connect') return;

  // Anti doble-conexión: el retry manda varios 'connect'; solo el primero
  // conecta (si no, se crearían 2 Room con la misma identidad → duplicate).
  if (_spikeRoom != null || _spikeBusy) {
    _hlog('ya conectado/conectando, ignoro connect repetido');
    return;
  }
  _spikeBusy = true;

  final url = data['url'] as String;
  final token = data['token'] as String;
  final channel = data['channel'] as String? ?? '?';
  _hlog('onReceiveData connect, canal=$channel');

  try {
    // bypassVoiceProcessing=true → MODE_NORMAL → mic libre para otras apps (R4).
    await lk.LiveKitClient.initialize(bypassVoiceProcessing: true);
    _hlog('LiveKitClient.initialize OK (isolate FGS)');

    final room = lk.Room();
    _spikeRoom = room;
    room.createListener()
      ..on<lk.TrackSubscribedEvent>((e) {
        _hlog('TrackSubscribed: ${e.track.kind} de ${e.participant.identity}');
      })
      ..on<lk.RoomReconnectedEvent>((_) {
        _hlog('Reconectado — re-forzando altavoz');
        unawaited(_forceSpeaker());
      });

    await room.connect(url, token);
    _hlog('room.connect OK → CONECTADO en el isolate del FGS');
    await _forceSpeaker(); // altavoz / stream multimedia (R5)
    _hlog('altavoz forzado (AndroidAudioConfiguration.media)');
  } catch (e) {
    _spikeRoom = null;
    _hlog('ERROR conectando en isolate: $e');
  } finally {
    _spikeBusy = false;
  }
}

Future<void> _forceSpeaker() async {
  try {
    await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration.media);
  } catch (e) {
    _hlog('setAndroidAudioConfiguration falló: $e');
  }
}

Future<void> spikeHandlerDisconnect() async {
  try {
    await _spikeRoom?.disconnect();
    await _spikeRoom?.dispose();
  } catch (_) {}
  _spikeRoom = null;
  _hlog('disconnect (onDestroy)');
}
