package com.cookoo.cookoo_video_export

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.transformer.*
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.roundToLong

/** Transformer copies the already encoded video and transcodes only the audio. */
internal class AudioMuxJob(val transformer: Transformer, val path: String, val reply: (Any?) -> Unit) {
    fun cancel() {
        transformer.cancel()
        File(path).delete()
    }
    companion object {
        fun start(context: Context, args: Map<String, Any?>, reply: (Any?) -> Unit,
                  done: () -> Unit): AudioMuxJob {
            val video = args["videoPath"] as String
            val audio = args["audioPath"] as String
            val path = args["path"] as String
            require(path != video && path != audio) { "Audio output must differ from its inputs." }
            // Retriever's duration is whole milliseconds, which stretches the
            // final video frame at rates such as 30 fps and 30000/1001 fps.
            val metadata = MediaExtractor()
            val durationUs = try {
                metadata.setDataSource(video)
                val track = (0 until metadata.trackCount).first {
                    metadata.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
                }
                val declared = metadata.getTrackFormat(track).getLong(MediaFormat.KEY_DURATION)
                metadata.selectTrack(track)
                val times = ArrayList<Long>()
                while (metadata.sampleTime >= 0) {
                    times.add(metadata.sampleTime)
                    if (!metadata.advance()) break
                }
                times.sort()
                // Extractor's declared duration may inherit the movie header's
                // coarser clock. Recover our CFR clock from sample timestamps;
                // retain the declared duration for arbitrary variable-rate files.
                if (times.size > 1 && times.first() == 0L) {
                    val period = times.last().toDouble() / (times.size - 1)
                    val cfr = period > 0 && times.zipWithNext().all { (a, b) -> abs((b - a) - period) <= 2 }
                    if (cfr) (period * times.size).roundToLong() else declared
                } else declared
            } finally { metadata.release() }
            require(durationUs > 0) { "The video has no readable duration." }
            val sonic = SonicAudioProcessor().apply { setOutputSampleRateHz(48000) }
            val channels = ChannelMixingAudioProcessor().apply {
                putChannelMixingMatrix(ChannelMixingMatrix.create(1, 2))
                putChannelMixingMatrix(ChannelMixingMatrix.create(2, 2))
            }
            val fade = FadeOut(durationUs, (args["fadeOutUs"] as? Number)?.toLong() ?: 0)
            val picture = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(video))))
                .setRemoveAudio(true).build()
            val audioItem = MediaItem.Builder().setUri(Uri.fromFile(File(audio)))
                .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder()
                    .setEndPositionMs((durationUs + 999) / 1000).build()).build()
            val track = EditedMediaItem.Builder(audioItem)
                .setRemoveVideo(true).build()
            val pictureSequence = EditedMediaItemSequence.Builder(listOf(picture)).build()
            val audioSequence = EditedMediaItemSequence.Builder(listOf(track))
                .setIsLooping(args["loop"] as? Boolean ?: true).build()
            val composition = Composition.Builder(pictureSequence, audioSequence)
                .setTransmuxVideo(true)
                .setEffects(Effects(listOf(sonic, channels, fade), emptyList())).build()
            val factory = DefaultEncoderFactory.Builder(context)
                .setRequestedAudioEncoderSettings(AudioEncoderSettings.Builder().setBitrate(192000).build()).build()
            val transformer = Transformer.Builder(context)
                .setEncoderFactory(factory)
                .setMuxerFactory(DurationMuxerFactory(durationUs))
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        done(); reply(mapOf("path" to path, "bytes" to File(path).length()))
                    }
                    override fun onError(composition: Composition, exportResult: ExportResult, exception: ExportException) {
                        File(path).delete(); done()
                        reply(AudioMuxError("failed", exception.message, null))
                    }
                }).build()
            File(path).delete()
            transformer.start(composition, path)
            return AudioMuxJob(transformer, path, reply)
        }
    }
}

private class FadeOut(private val durationUs: Long, private val fadeUs: Long) : BaseAudioProcessor() {
    private var samples = 0L
    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        return inputAudioFormat
    }
    override fun onFlush() { samples = 0 }
    override fun queueInput(inputBuffer: ByteBuffer) {
        val output = replaceOutputBuffer(inputBuffer.remaining())
        while (inputBuffer.remaining() >= 2) {
            val frame = samples / inputAudioFormat.channelCount
            val timeUs = frame * 1000000 / inputAudioFormat.sampleRate
            val gain = if (fadeUs <= 0) 1.0 else ((durationUs - timeUs).toDouble() / fadeUs).coerceIn(0.0, 1.0)
            output.putShort((inputBuffer.short * gain).toInt().toShort())
            samples++
        }
        output.flip()
    }
}

internal data class AudioMuxError(val code: String, val message: String?, val details: Any? = null)

/** Trim AAC padding at the video boundary, including the final sample duration. */
private class DurationMuxerFactory(private val durationUs: Long) : androidx.media3.muxer.Muxer.Factory {
    private val factory = DefaultMuxer.Factory().setVideoDurationUs(durationUs)
    override fun getSupportedSampleMimeTypes(trackType: Int) = factory.getSupportedSampleMimeTypes(trackType)
    override fun create(path: String): androidx.media3.muxer.Muxer {
        val target = factory.create(path)
        return object : androidx.media3.muxer.Muxer {
            private val audioTracks = mutableSetOf<Int>()
            override fun addTrack(format: androidx.media3.common.Format): Int {
                val id = target.addTrack(format)
                if (MimeTypes.isAudio(format.sampleMimeType)) audioTracks.add(id)
                return id
            }
            override fun writeSampleData(track: Int, data: ByteBuffer, info: androidx.media3.muxer.BufferInfo) {
                if (track in audioTracks && info.presentationTimeUs >= durationUs) return
                target.writeSampleData(track, data, info)
            }
            override fun addMetadataEntry(entry: androidx.media3.common.Metadata.Entry) = target.addMetadataEntry(entry)
            override fun close() {
                for (track in audioTracks) target.writeSampleData(track, ByteBuffer.allocateDirect(0),
                    androidx.media3.muxer.BufferInfo(durationUs, 0, C.BUFFER_FLAG_END_OF_STREAM))
                target.close()
            }
        }
    }
}
