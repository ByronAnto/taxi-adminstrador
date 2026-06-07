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

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show Helper, AndroidAudioConfiguration;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/radio_power_service.dart';

/// Señales del protocolo del spike (strings/maps que cruzan isolates).
const String kSpikeNeedToken = '[SPIKE] need-token';
const String kSpikeLogPrefix = '[SPIKE] log:';

// ───────────────────────── MAIN ISOLATE ─────────────────────────

/// Corre en el isolate PRINCIPAL (autenticado). Lee el último canal de prefs,
/// pide el token a la Cloud Function y se lo envía al handler del FGS.
Future<void> spikeProvideTokenToHandler() async {
  try {
    // GUARDA anti doble-identidad: si el radio normal está ON, el isolate
    // principal ya está conectado con esta identidad → NO conectar el spike.
    if (RadioPowerService.instance.isOn) {
      FlutterForegroundTask.sendDataToTask({
        'spike': 'error',
        'msg': 'radio normal ENCENDIDO — apágalo y deja solo "Activo" (GPS) '
            'para probar el spike sin duplicateIdentity',
      });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final channelId = prefs.getString('radio.power.lastChannelId');
    if (channelId == null || channelId.isEmpty) {
      FlutterForegroundTask.sendDataToTask({
        'spike': 'error',
        'msg': 'sin lastChannelId en prefs (enciende el radio una vez primero)',
      });
      return;
    }

    final res = await FirebaseFunctions.instance
        .httpsCallable('generateLiveKitToken')
        .call({'channelName': channelId}).timeout(const Duration(seconds: 15));
    final data = (res.data as Map?) ?? const {};
    final url = data['url'] as String?;
    final token = data['token'] as String?;
    if (url == null || token == null || url.isEmpty || token.isEmpty) {
      FlutterForegroundTask.sendDataToTask(
          {'spike': 'error', 'msg': 'token inválido de la CF'});
      return;
    }

    FlutterForegroundTask.sendDataToTask({
      'spike': 'connect',
      'url': url,
      'token': token,
      'channel': channelId,
    });
  } catch (e) {
    FlutterForegroundTask.sendDataToTask({'spike': 'error', 'msg': '$e'});
  }
}

// ───────────────────────── HANDLER ISOLATE (FGS) ─────────────────────────

lk.Room? _spikeRoom;

void _hlog(String m) => FlutterForegroundTask.sendDataToMain('$kSpikeLogPrefix $m');

/// Corre en el isolate del FGS. Conexión LiveKit cruda con el token recibido.
Future<void> spikeHandlerConnect(Map data) async {
  final kind = data['spike'];
  if (kind == 'error') {
    _hlog('main reportó error: ${data['msg']}');
    return;
  }
  if (kind != 'connect') return;

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
    _hlog('ERROR conectando en isolate: $e');
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
