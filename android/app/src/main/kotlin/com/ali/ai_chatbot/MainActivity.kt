package com.basit.ai_chatbot

import io.flutter.embedding.android.FlutterActivity
import android.os.Build
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.provider.Settings
import android.speech.SpeechRecognizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var voiceChannel: MethodChannel? = null
    private var focusRequest: AudioFocusRequest? = null
    private val audioManager by lazy { getSystemService(AUDIO_SERVICE) as AudioManager }
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var focusGeneration = 0

    @Suppress("DEPRECATION")
    private fun releaseVoiceFocus() {
        focusGeneration++
        if (Build.VERSION.SDK_INT >= 26) focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        else focusListener?.let { audioManager.abandonAudioFocus(it) }
        focusRequest = null
        focusListener = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai_mind/appearance")
            .setMethodCallHandler { call, result ->
                if (call.method == "supportsDarkNavigationBar") {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                } else {
                    result.notImplemented()
                }
            }
        voiceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ai_mind/voice")
        voiceChannel!!.setMethodCallHandler { call, result ->
            val prefs = getSharedPreferences("voice_permissions", MODE_PRIVATE)
            when (call.method) {
                "microphoneStatus" -> {
                    val granted = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
                    val asked = prefs.getBoolean("microphone_requested", false)
                    result.success(if (granted) "granted" else if (asked && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) "permanentlyDenied" else "denied")
                }
                "markMicrophoneRequested" -> {
                    prefs.edit().putBoolean("microphone_requested", true).apply()
                    result.success(null)
                }
                "recognitionAvailable" -> result.success(SpeechRecognizer.isRecognitionAvailable(this))
                "openAppSettings", "openSpeechSettings", "openRecognitionSettings" -> {
                    val intent = if (call.method == "openAppSettings")
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                    else if (call.method == "openRecognitionSettings") Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)
                    else Intent("com.android.settings.TTS_SETTINGS")
                    try { startActivity(intent); result.success(true) }
                    catch (_: Exception) { result.success(false) }
                }
                "requestPlaybackFocus" -> {
                    releaseVoiceFocus()
                    val generation = ++focusGeneration
                    val listener = AudioManager.OnAudioFocusChangeListener { change ->
                        if (change < 0) runOnUiThread {
                            if (generation == focusGeneration) voiceChannel?.invokeMethod("audioFocusLost", null)
                        }
                    }
                    focusListener = listener
                    @Suppress("DEPRECATION")
                    val granted = if (Build.VERSION.SDK_INT >= 26) {
                        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                            .setAudioAttributes(AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                            .setOnAudioFocusChangeListener(listener).build()
                        focusRequest = request
                        audioManager.requestAudioFocus(request)
                    } else audioManager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    result.success(granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
                }
                "releasePlaybackFocus" -> { releaseVoiceFocus(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        releaseVoiceFocus()
        voiceChannel?.setMethodCallHandler(null)
        voiceChannel = null
        super.onDestroy()
    }
}
