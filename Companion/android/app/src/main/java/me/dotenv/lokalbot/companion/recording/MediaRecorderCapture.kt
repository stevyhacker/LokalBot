package me.dotenv.lokalbot.companion.recording

import android.annotation.SuppressLint
import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.util.Log

/**
 * ADTS AAC straight to the file: every frame carries its own header, so a
 * killed process or a dead battery leaves a readable file. An MP4 or M4A
 * container would need finishing on stop and must not be used here.
 */
class MediaRecorderCapture(private val context: Context) : AudioCapture {
    private var recorder: MediaRecorder? = null

    @Synchronized
    override fun start(path: String, onError: () -> Unit) {
        // VOICE_RECOGNITION is held by the Android compatibility rules to a flat
        // response, with noise reduction and automatic gain off by default, so the
        // file keeps what the room said for the computer's transcription. What MIC
        // does varies by maker. Not every device offers it, so MIC is the fallback.
        recorder = try {
            started(MediaRecorder.AudioSource.VOICE_RECOGNITION, path, onError)
        } catch (e: Exception) {
            Log.w(TAG, "voice recognition source failed, trying the microphone: $e")
            started(MediaRecorder.AudioSource.MIC, path, onError)
        }
    }

    // RecordingService checks the permission before it asks for this.
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
        // Throws when nothing was captured yet; the file is what it is either way.
        runCatching { current.stop() }
        current.release()
    }

    private companion object {
        const val TAG = "LokalBot"
        const val SAMPLE_RATE_HZ = 48_000
        const val BIT_RATE = 64_000
    }
}
