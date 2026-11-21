package me.dotenv.lokalbot.companion.recording

import android.annotation.SuppressLint
import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.util.Log

class MediaRecorderCapture(private val context: Context) : AudioCapture {
    private var recorder: MediaRecorder? = null

    @Synchronized
    override fun start(path: String, onError: () -> Unit) {
        recorder = try {
            started(MediaRecorder.AudioSource.VOICE_RECOGNITION, path, onError)
        } catch (e: Exception) {
            Log.w(TAG, "voice recognition source failed, trying the microphone: $e")
            started(MediaRecorder.AudioSource.MIC, path, onError)
        }
    }

    @SuppressLint("MissingPermission")
    private fun started(source: Int, path: String, onError: () -> Unit): MediaRecorder {
        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            recorder.setAudioSource(source)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.AAC_ADTS)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioChannels(1)
            recorder.setAudioSamplingRate(SAMPLE_RATE_HZ)
            recorder.setAudioEncodingBitRate(BIT_RATE)
            recorder.setOutputFile(path)
            recorder.setOnErrorListener { _, what, extra ->
                Log.w(TAG, "recorder error $what ($extra)")
                onError()
            }
            recorder.prepare()
            recorder.start()
        } catch (e: Exception) {
            recorder.release()
            throw e
        }
        return recorder
    }

    @Synchronized
    override fun maxAmplitude(): Int = runCatching { recorder?.maxAmplitude ?: 0 }.getOrDefault(0)

    @Synchronized
    override fun stop() {
        val current = recorder ?: return
        recorder = null
        runCatching { current.stop() }
        current.release()
    }

    private companion object {
        const val TAG = "LokalBot"
        const val SAMPLE_RATE_HZ = 48_000
        const val BIT_RATE = 64_000
    }
}
