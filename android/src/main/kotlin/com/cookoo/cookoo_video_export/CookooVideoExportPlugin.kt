package com.cookoo.cookoo_video_export

import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.system.ErrnoException
import android.system.OsConstants
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The native half of `NativeVideoEncoder` (lib/features/export/data/):
 * MediaCodec + MediaMuxer for H.264 and HEVC in .mp4. Android has no ProRes
 * encoder, so capabilities never offer it.
 *
 * Channel `cookoo_video_export/encoder`:
 *   capabilities → {codecs: {name: longestEdge}, freeBytes}
 *   start {codec, width, height, fpsNum, fpsDen, bitrate, path} → id
 *   append {id, frame, width, height, rgba} → null, once the frame is in
 *   finish {id} → {path, bytes}
 *   cancel {id} → null
 * Errors: `out_of_space`, `unsupported`, `failed`.
 *
 * Work runs on one thread; each call answers when it's done, which is the
 * back-pressure that keeps Dart a single frame ahead.
 */
class CookooVideoExportPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var cacheDir: File
    private lateinit var context: android.content.Context
    private val audioJobs = HashMap<Int, AudioMuxJob>()
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val sessions = HashMap<Int, EncodeSession>()
    private var nextId = 1

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        cacheDir = context.cacheDir
        channel = MethodChannel(binding.binaryMessenger, "cookoo_video_export/encoder")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        audioJobs.values.forEach { it.cancel(); it.reply(AudioMuxError("cancelled", "Engine detached.", null)) }
        audioJobs.clear()
        worker.execute {
            sessions.values.forEach { it.cancel() }
            sessions.clear()
        }
        worker.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "cancelAudio") {
            call.argument<Int>("id")?.let { id -> audioJobs.remove(id)?.let { job ->
                job.cancel(); job.reply(AudioMuxError("cancelled", "Audio mux cancelled.", null))
            } }
            result.success(null); return
        }
        if (call.method == "muxAudio") {
            try {
                val id = call.argument<Int>("id")!!
                audioJobs[id] = AudioMuxJob.start(context, call.arguments as Map<String, Any?>, { value ->
                    if (value is AudioMuxError) result.error(value.code, value.message, value.details)
                    else result.success(value)
                }, { audioJobs.remove(id) })
            } catch (error: Exception) { result.error("failed", error.message, null) }
            return
        }
        worker.execute {
            try {
                val reply: Any? = when (call.method) {
                    "capabilities" -> capabilities()
                    "supports" -> {
                        val mime = MIMES[call.argument<String>("codec")]
                        if (mime == null) false else {
                            val w = call.argument<Int>("width")!!
                            val h = call.argument<Int>("height")!!
                            val fps = call.argument<Int>("fpsNum")!!.toDouble() / call.argument<Int>("fpsDen")!!
                            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                                info.isEncoder && info.supportedTypes.any { it.equals(mime, true) } &&
                                runCatching { info.getCapabilitiesForType(mime).videoCapabilities.areSizeAndRateSupported(w, h, fps) }.getOrDefault(false)
                            }
                        }
                    }
                    "start" -> {
                        val session = EncodeSession(
                            codec = call.argument<String>("codec")!!,
                            width = call.argument<Int>("width")!!,
                            height = call.argument<Int>("height")!!,
                            fpsNum = call.argument<Int>("fpsNum")!!,
                            fpsDen = call.argument<Int>("fpsDen")!!,
                            bitrate = call.argument<Int>("bitrate")!!,
                            path = call.argument<String>("path")!!,
                        )
                        val id = nextId++
                        sessions[id] = session
                        id
                    }
                    "append" -> {
                        val id = call.argument<Int>("id")!!
                        val session = sessions[id] ?: throw EncoderError("failed", "No such render.")
                        try {
                            session.append(
                                rgba = call.argument<ByteArray>("rgba")!!,
                                frame = call.argument<Int>("frame")!!.toLong(),
                                width = call.argument<Int>("width")!!,
                                height = call.argument<Int>("height")!!,
                            )
                        } catch (e: Exception) {
                            sessions.remove(id)?.cancel()
                            throw e
                        }
                        null
                    }
                    "finish" -> {
                        val session = sessions.remove(call.argument<Int>("id")!!)
                            ?: throw EncoderError("failed", "No such render.")
                        val (path, bytes) = session.finish()
                        mapOf("path" to path, "bytes" to bytes)
                    }
                    "cancel" -> {
                        call.argument<Int>("id")?.let { sessions.remove(it)?.cancel() }
                        null
                    }
                    else -> {
                        main.post { result.notImplemented() }
                        return@execute
                    }
                }
                main.post { result.success(reply) }
            } catch (e: EncoderError) {
                main.post { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                val error = EncoderError.from(e)
                main.post { result.error(error.code, error.message, null) }
            }
        }
    }

    /**
     * The longest edge each codec's best hardware encoder takes, checked
     * at 16:9 in both orientations at 30 fps.
     */
    private fun capabilities(): Map<String, Any> {
        val codecs = HashMap<String, Int>()
        val codecs60 = HashMap<String, Int>()
        val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { it.isEncoder }
        fun maxEdge(mime: String, fps: Double): Int? =
            listOf(3840, 1920, 1280).firstOrNull { edge ->
                val short = edge * 9 / 16
                infos.any { info ->
                    info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
                        info.getCapabilitiesForType(mime).videoCapabilities?.let {
                            it.areSizeAndRateSupported(edge, short, fps) &&
                                it.areSizeAndRateSupported(short, edge, fps)
                        } == true
                }
            }
        for ((name, mime) in MIMES) {
            maxEdge(mime, 30.0)?.let { codecs[name] = it }
            maxEdge(mime, 60.0)?.let { codecs60[name] = it }
        }
        return mapOf("codecs" to codecs, "codecs60" to codecs60, "freeBytes" to StatFs(cacheDir.path).availableBytes)
    }

    companion object {
        val MIMES = mapOf("h264" to MediaFormat.MIMETYPE_VIDEO_AVC, "hevc" to MediaFormat.MIMETYPE_VIDEO_HEVC)
    }
}

private class EncoderError(val code: String, override val message: String) : Exception(message) {
    companion object {
        /** A full disk shows up as ENOSPC somewhere in the cause chain. */
        fun from(e: Throwable): EncoderError {
            var cause: Throwable? = e
            while (cause != null) {
                if (cause is ErrnoException && cause.errno == OsConstants.ENOSPC) return outOfSpace()
                if (cause is IOException && cause.message?.contains("ENOSPC") == true) return outOfSpace()
                cause = cause.cause
            }
            return EncoderError("failed", e.message ?: "The encoder stopped.")
        }

        fun outOfSpace() = EncoderError("out_of_space", "Not enough free space.")
    }
}

/** One file being written. Only ever touched from the plugin's worker thread. */
private class EncodeSession(
    codec: String,
    private val width: Int,
    private val height: Int,
    private val fpsNum: Int,
    private val fpsDen: Int,
    bitrate: Int,
    private val path: String,
) {
    private val encoder: MediaCodec
    private val muxer: MediaMuxer
    private val info = MediaCodec.BufferInfo()
    private var track = -1
    private var muxing = false
    private var lastFrame = -1L

    init {
        val mime = CookooVideoExportPlugin.MIMES[codec]
            ?: throw EncoderError("unsupported", "This device can’t encode that codec.")
        val format = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setFloat(MediaFormat.KEY_FRAME_RATE, fpsNum.toFloat() / fpsDen)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // Credits are graphics made in sRGB; tag them Rec. 709 like any HD master.
            setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
        }
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: throw EncoderError("unsupported", "This device can’t encode $width × $height in that codec.")
        encoder = MediaCodec.createByCodecName(name)
        try {
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()
            File(path).delete()
            muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (e: Exception) {
            encoder.release()
            throw EncoderError.from(e)
        }
    }

    private fun timeUs(frame: Long) = frame * fpsDen * 1_000_000L / fpsNum

    /** Converts premultiplied RGBA to the encoder's YUV 4:2:0 and queues it at its own time. */
    fun append(rgba: ByteArray, frame: Long, width: Int, height: Int) {
        if (width != this.width || height != this.height || rgba.size < width * height * 4) {
            throw EncoderError("failed", "A frame came in at the wrong size.")
        }
        var index: Int
        while (true) {
            index = encoder.dequeueInputBuffer(TIMEOUT_US)
            if (index >= 0) break
            drain(endOfStream = false)
        }
        val image = encoder.getInputImage(index) ?: throw EncoderError("failed", "The encoder gave no frame to fill.")
        writeYuv(rgba, image)
        encoder.queueInputBuffer(index, 0, width * height * 3 / 2, timeUs(frame), 0)
        lastFrame = frame
        drain(endOfStream = false)
    }

    fun finish(): Pair<String, Long> {
        try {
            var index: Int
            while (true) {
                index = encoder.dequeueInputBuffer(TIMEOUT_US)
                if (index >= 0) break
                drain(endOfStream = false)
            }
            encoder.queueInputBuffer(index, 0, 0, timeUs(lastFrame + 1), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            drain(endOfStream = true)
            if (muxing) {
                // MediaMuxer otherwise guesses the final sample's duration.
                // Preserve the exact frame clock, including non-integer rates.
                val end = MediaCodec.BufferInfo().apply {
                    set(0, 0, timeUs(lastFrame + 1), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                }
                muxer.writeSampleData(track, ByteBuffer.allocateDirect(0), end)
            }
            encoder.stop()
            encoder.release()
            if (muxing) muxer.stop()
            muxer.release()
        } catch (e: Exception) {
            cancel()
            throw if (e is EncoderError) e else EncoderError.from(e)
        }
        return path to File(path).length()
    }

    fun cancel() {
        runCatching { encoder.stop() }
        runCatching { encoder.release() }
        runCatching { if (muxing) muxer.stop() }
        runCatching { muxer.release() }
        File(path).delete()
    }

    /** Moves whatever the encoder has finished into the file. */
    private fun drain(endOfStream: Boolean) {
        while (true) {
            val index = encoder.dequeueOutputBuffer(info, TIMEOUT_US)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(encoder.outputFormat)
                    muxer.start()
                    muxing = true
                }
                index >= 0 -> {
                    val buffer = encoder.getOutputBuffer(index)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0 && muxing) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(track, buffer, info)
                    }
                    encoder.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    /**
     * BT.709 limited range, in integers. Chroma is the average of each 2×2
     * block, so the edges of white type stay clean. Plane strides are read
     * from the image — encoders differ (planar, semi-planar, padded rows).
     */
    private fun writeYuv(rgba: ByteArray, image: Image) {
        val y = image.planes[0]
        val u = image.planes[1]
        val v = image.planes[2]
        val yBuf = y.buffer
        val yRow = y.rowStride
        val yPix = y.pixelStride
        for (row in 0 until height) {
            var src = row * width * 4
            var dst = row * yRow
            for (col in 0 until width) {
                val r = rgba[src].toInt() and 0xFF
                val g = rgba[src + 1].toInt() and 0xFF
                val b = rgba[src + 2].toInt() and 0xFF
                yBuf.put(dst, (((47 * r + 157 * g + 16 * b + 128) shr 8) + 16).toByte())
                src += 4
                dst += yPix
            }
        }
        val uBuf = u.buffer
        val vBuf = v.buffer
        for (row in 0 until height / 2) {
            for (col in 0 until width / 2) {
                val a = (row * 2 * width + col * 2) * 4
                val c = a + width * 4
                val r = ((rgba[a].toInt() and 0xFF) + (rgba[a + 4].toInt() and 0xFF) + (rgba[c].toInt() and 0xFF) + (rgba[c + 4].toInt() and 0xFF)) shr 2
                val g = ((rgba[a + 1].toInt() and 0xFF) + (rgba[a + 5].toInt() and 0xFF) + (rgba[c + 1].toInt() and 0xFF) + (rgba[c + 5].toInt() and 0xFF)) shr 2
                val b = ((rgba[a + 2].toInt() and 0xFF) + (rgba[a + 6].toInt() and 0xFF) + (rgba[c + 2].toInt() and 0xFF) + (rgba[c + 6].toInt() and 0xFF)) shr 2
                uBuf.put(row * u.rowStride + col * u.pixelStride, (((-26 * r - 86 * g + 112 * b + 128) shr 8) + 128).toByte())
                vBuf.put(row * v.rowStride + col * v.pixelStride, (((112 * r - 102 * g - 10 * b + 128) shr 8) + 128).toByte())
            }
        }
    }

    companion object {
        const val TIMEOUT_US = 10_000L
    }
}
