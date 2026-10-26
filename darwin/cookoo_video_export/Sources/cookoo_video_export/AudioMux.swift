import AVFoundation
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

/// Encode mixed PCM to AAC first, then use AVFoundation passthrough to
/// preserve compressed video timing (including negative DTS for B-frames).
final class AudioMuxJob {
  private let lock = NSLock()
  private var stopped = false
  func cancel() { lock.lock(); stopped = true; lock.unlock() }
  private var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

  func run(_ args: [String: Any]) throws -> [String: Any] {
    guard let videoPath = args["videoPath"] as? String,
          let audioPath = args["audioPath"] as? String,
          let path = args["path"] as? String, path != videoPath, path != audioPath else {
      throw failure("Invalid audio mux paths.")
    }
    let output = URL(fileURLWithPath: path)
    let scratch = output.deletingLastPathComponent().appendingPathComponent("audio-\(UUID().uuidString).m4a")
    try? FileManager.default.removeItem(at: output)
    var completed = false
    defer {
      try? FileManager.default.removeItem(at: scratch)
      if !completed { try? FileManager.default.removeItem(at: output) }
    }
    let video = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    let audio = AVURLAsset(url: URL(fileURLWithPath: audioPath))
    guard let v = video.tracks(withMediaType: .video).first,
          let a = audio.tracks(withMediaType: .audio).first,
          video.duration.isNumeric, audio.duration.isNumeric,
          CMTimeGetSeconds(audio.duration) > 0 else {
      throw failure("The selected files have no readable video or audio track.")
    }
    let duration = video.duration
    let composition = AVMutableComposition()
    let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    var position = CMTime.zero
    repeat {
      if cancelled { throw failure() }
      let count = CMTimeMinimum(audio.duration, CMTimeSubtract(duration, position))
      try track.insertTimeRange(CMTimeRange(start: .zero, duration: count), of: a, at: position)
      position = CMTimeAdd(position, count)
    } while (args["loop"] as? Bool ?? true) && CMTimeCompare(position, duration) < 0
    let mix = AVMutableAudioMix()
    let parameters = AVMutableAudioMixInputParameters(track: track)
    let fade = min(Double(args["fadeOutUs"] as? Int ?? 0) / 1_000_000, CMTimeGetSeconds(position))
    if fade > 0 {
      let fadeTime = CMTime(seconds: fade, preferredTimescale: 48000)
      parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
        timeRange: CMTimeRange(start: CMTimeSubtract(position, fadeTime), duration: fadeTime))
    }
    mix.inputParameters = [parameters]
    let reader = try AVAssetReader(asset: composition)
    let decoded = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    decoded.audioMix = mix
    reader.add(decoded)
    let writer = try AVAssetWriter(outputURL: scratch, fileType: .m4a)
    let encoded = AVAssetWriterInput(mediaType: .audio, outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000,
    ])
    encoded.expectsMediaDataInRealTime = false
    writer.add(encoded)
    guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? failure("Audio processing could not start.") }
    writer.startSession(atSourceTime: .zero)
    var audioCompleted = false
    defer { if !audioCompleted { reader.cancelReading(); writer.cancelWriting() } }
    var lastProgress = Date()
    while true {
      if cancelled { throw failure() }
      if !encoded.isReadyForMoreMediaData {
        if writer.status == .failed { throw writer.error ?? failure("Audio encoding failed.") }
        if Date().timeIntervalSince(lastProgress) > 30 { throw failure("The audio encoder timed out.") }
        usleep(2_000); continue
      }
      guard let sample = decoded.copyNextSampleBuffer() else { break }
      guard encoded.append(sample) else { throw writer.error ?? failure("Audio encoding failed.") }
      lastProgress = Date()
    }
    if reader.status == .failed { throw reader.error ?? failure("The music could not be decoded.") }
    encoded.markAsFinished()
    writer.endSession(atSourceTime: position)
    let audioDone = DispatchSemaphore(value: 0)
    writer.finishWriting { audioDone.signal() }
    while audioDone.wait(timeout: .now() + 0.1) == .timedOut {
      if cancelled { throw failure() }
      if Date().timeIntervalSince(lastProgress) > 30 { throw failure("Finalizing music timed out.") }
    }
    guard writer.status == .completed else { throw writer.error ?? failure("Audio encoding failed.") }
    audioCompleted = true
    if cancelled { throw failure() }

    let encodedAudio = AVURLAsset(url: scratch)
    guard let finalAudio = encodedAudio.tracks(withMediaType: .audio).first else { throw failure("The audio file is empty.") }
    let final = AVMutableComposition()
    let videoTrack = final.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: v, at: .zero)
    videoTrack.preferredTransform = v.preferredTransform
    let audioTrack = final.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(encodedAudio.duration, duration)), of: finalAudio, at: .zero)
    guard let export = AVAssetExportSession(asset: final, presetName: AVAssetExportPresetPassthrough) else { throw failure("Video passthrough is unavailable.") }
    export.outputURL = output
    export.outputFileType = path.hasSuffix(".mov") ? .mov : .mp4
    export.timeRange = CMTimeRange(start: .zero, duration: duration)
    let exportDone = DispatchSemaphore(value: 0)
    export.exportAsynchronously { exportDone.signal() }
    let deadline = Date().addingTimeInterval(120)
    while exportDone.wait(timeout: .now() + 0.1) == .timedOut {
      if cancelled || Date() > deadline {
        export.cancelExport()
        throw failure(cancelled ? "Audio mux cancelled." : "Video muxing timed out.")
      }
    }
    guard export.status == .completed else { throw export.error ?? failure("Video muxing failed.") }
    if cancelled { throw failure() }
    try preserveVideoTiming(from: URL(fileURLWithPath: videoPath), to: output)
    completed = true
    let bytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    return ["path": path, "bytes": bytes]
  }
  private func failure(_ message: String = "Audio mux cancelled.") -> NSError {
    NSError(domain: "cookoo_video_export", code: cancelled ? 3 : 4, userInfo: [NSLocalizedDescriptionKey: message])
  }
}


/// AVFoundation passthrough may extend the last decode sample to the
/// presentation end of a B-frame stream. Restore the original CFR timing
/// without moving atoms or touching compressed samples or chunk offsets.
func preserveVideoTiming(from source: URL, to output: URL) throws {
  guard let original = try videoTiming(source), let copied = try videoTiming(output),
        original.frames == copied.frames,
        original.entries.allSatisfy({ $0.delta == original.entries.first?.delta }),
        let sourceDelta = original.entries.first?.delta, sourceDelta > 0,
        original.scale > 0, copied.scale > 0, original.frames > 0 else { return }
  // Passthrough can change an integer-rate track from 30 to 600 ticks/second.
  // Compare and restore durations in the output track's own time base.
  let scaled = UInt64(sourceDelta).multipliedReportingOverflow(by: copied.scale)
  guard !scaled.overflow, scaled.partialValue % original.scale == 0 else { return }
  let delta = scaled.partialValue / original.scale
  let sourceDuration = original.frames.multipliedReportingOverflow(by: UInt64(sourceDelta))
  let expected = original.frames.multipliedReportingOverflow(by: delta)
  guard delta > 0, delta <= UInt64(UInt32.max),
        !sourceDuration.overflow, original.duration == sourceDuration.partialValue,
        !expected.overflow,
        copied.durationBytes == 8 || expected.partialValue <= UInt64(UInt32.max),
        let tail = copied.entries.last, tail.count == 1, UInt64(tail.delta) > delta,
        copied.entries.dropLast().allSatisfy({ UInt64($0.delta) == delta }) else { return }
  let handle = try FileHandle(forUpdating: output)
  defer { try? handle.close() }
  func write(_ value: UInt64, at offset: UInt64, bytes: Int) throws {
    var data = Data(repeating: 0, count: bytes)
    for index in 0..<bytes { data[index] = UInt8((value >> ((bytes - index - 1) * 8)) & 255) }
    try handle.seek(toOffset: offset); try handle.write(contentsOf: data)
  }
  try write(delta, at: copied.tailOffset, bytes: 4)
  try write(expected.partialValue, at: copied.durationOffset, bytes: copied.durationBytes)
}

private struct Timing {
  let scale: UInt64, duration: UInt64, frames: UInt64
  let entries: [(count: UInt32, delta: UInt32)]
  let tailOffset: UInt64, durationOffset: UInt64
  let durationBytes: Int
}
private struct Box { let type: String, payload: Int, end: Int }
private func number(_ data: Data, _ offset: Int, _ bytes: Int) -> UInt64? {
  guard offset >= 0, offset + bytes <= data.count else { return nil }
  var result: UInt64 = 0
  for index in offset..<(offset + bytes) { result = (result << 8) | UInt64(data[index]) }
  return result
}
private func boxes(_ data: Data, _ start: Int, _ end: Int) -> [Box] {
  var result: [Box] = [], offset = start
  while offset + 8 <= end {
    guard let short = number(data, offset, 4) else { break }
    let header = short == 1 ? 16 : 8
    let length = short == 1 ? number(data, offset + 8, 8) : (short == 0 ? UInt64(end - offset) : short)
    guard let size = length, size >= UInt64(header), size <= UInt64(end - offset) else { break }
    let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
    result.append(Box(type: type, payload: offset + header, end: offset + Int(size)))
    offset += Int(size)
  }
  return result
}
private func videoTiming(_ url: URL) throws -> Timing? {
  let file = try FileHandle(forReadingFrom: url)
  defer { try? file.close() }
  let fileSize = try file.seekToEnd()
  var offset: UInt64 = 0
  while offset + 8 <= fileSize {
    try file.seek(toOffset: offset)
    guard let header = try file.read(upToCount: 16), header.count >= 8,
          let short = number(header, 0, 4) else { return nil }
    let size = short == 1 ? number(header, 8, 8) : (short == 0 ? fileSize - offset : short)
    let headerSize = short == 1 ? 16 : 8
    guard let length = size, length >= UInt64(headerSize), length <= fileSize - offset else { return nil }
    if String(data: header[4..<8], encoding: .ascii) == "moov" {
      // Only the small index is read, never the video/audio payload.
      guard length <= 64 * 1024 * 1024 else { return nil }
      try file.seek(toOffset: offset)
      guard let data = try file.read(upToCount: Int(length)), data.count == Int(length) else { return nil }
      for track in boxes(data, headerSize, data.count) where track.type == "trak" {
        guard let media = boxes(data, track.payload, track.end).first(where: { $0.type == "mdia" }) else { continue }
        let children = boxes(data, media.payload, media.end)
        guard let handler = children.first(where: { $0.type == "hdlr" }), handler.payload + 12 <= handler.end,
              String(data: data[(handler.payload + 8)..<(handler.payload + 12)], encoding: .ascii) == "vide",
              let mdhd = children.first(where: { $0.type == "mdhd" }),
              let minf = children.first(where: { $0.type == "minf" }),
              let stbl = boxes(data, minf.payload, minf.end).first(where: { $0.type == "stbl" }),
              let stts = boxes(data, stbl.payload, stbl.end).first(where: { $0.type == "stts" }),
              stts.payload + 8 <= stts.end, mdhd.payload < mdhd.end,
              let count = number(data, stts.payload + 4, 4), count > 0,
              count <= UInt64((stts.end - stts.payload - 8) / 8) else { continue }
        let wide = data[mdhd.payload] == 1
        let scaleAt = mdhd.payload + (wide ? 20 : 12), durationAt = scaleAt + 4
        guard durationAt + (wide ? 8 : 4) <= mdhd.end,
              let scale = number(data, scaleAt, 4), let duration = number(data, durationAt, wide ? 8 : 4) else { return nil }
        var entries: [(count: UInt32, delta: UInt32)] = [], frames: UInt64 = 0
        for index in 0..<Int(count) {
          let at = stts.payload + 8 + index * 8
          guard let n = number(data, at, 4), let d = number(data, at + 4, 4) else { return nil }
          frames += n; entries.append((UInt32(n), UInt32(d)))
        }
        return Timing(scale: scale, duration: duration, frames: frames, entries: entries,
          tailOffset: offset + UInt64(stts.payload + 8 + (Int(count) - 1) * 8 + 4),
          durationOffset: offset + UInt64(durationAt), durationBytes: wide ? 8 : 4)
      }
      return nil
    }
    offset += length
  }
  return nil
}
