import AVFoundation
import Accelerate
import Flutter
import VideoToolbox

/// The native half of `NativeVideoEncoder` (lib/features/export/data/):
/// AVAssetWriter for H.264 and HEVC (.mp4) and ProRes 422 HQ / 4444 (.mov).
///
/// Channel `cookoo_video_export/encoder`:
///   capabilities → {codecs: {name: longestEdge}, freeBytes}
///   start {codec, width, height, fpsNum, fpsDen, bitrate, path} → id
///   append {id, frame, width, height, rgba} → nil, once the frame is in
///   finish {id} → {path, bytes}
///   cancel {id} → nil
/// Errors: `out_of_space`, `unsupported`, `failed`.
///
/// Work runs on one serial queue; each call answers when it's done, which
/// is the back-pressure that keeps Dart a single frame ahead.
public final class CookooVideoExportPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "com.cookoo.video_export", qos: .userInitiated)
  private var sessions: [Int: EncodeSession] = [:]
  private var nextId = 1
  private var audioJobs: [Int: AudioMuxJob] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "cookoo_video_export/encoder", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(CookooVideoExportPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "cancelAudio" {
      if let id = args["id"] as? Int { audioJobs[id]?.cancel() }
      result(nil); return
    }
    if call.method == "muxAudio" {
      guard let id = args["id"] as? Int else { result(FlutterError(code: "invalid_arguments", message: "Missing audio job id.", details: nil)); return }
      let job = AudioMuxJob()
      audioJobs[id] = job
      DispatchQueue.global(qos: .userInitiated).async {
        let reply: Any
        do { reply = try job.run(args) }
        catch {
          let native = error as NSError
          let mapped = EncoderError.from(error)
          let cancelled = native.domain == "cookoo_video_export" && native.code == 3
          reply = FlutterError(code: cancelled ? "cancelled" : mapped.code, message: error.localizedDescription, details: nil)
        }
        DispatchQueue.main.async { self.audioJobs.removeValue(forKey: id); result(reply) }
      }
      return
    }
    queue.async {
      let reply: Any?
      do {
        switch call.method {
        case "capabilities":
          reply = Self.capabilities()
        case "supports":
          guard let name = args["codec"] as? String, let codec = EncoderCodec(rawValue: name),
                let w = args["width"] as? Int, let h = args["height"] as? Int,
                let n = args["fpsNum"] as? Int, let d = args["fpsDen"] as? Int,
                w > 0, h > 0, n > 0, d > 0 else { throw EncoderError.unsupported("Invalid video settings.") }
          reply = codec.canEncode(width: w, height: h, fps: Double(n) / Double(d))
        case "start":
          let session = try EncodeSession(args)
          let id = self.nextId
          self.nextId += 1
          self.sessions[id] = session
          reply = id
        case "append":
          guard let session = self.session(args), let rgba = args["rgba"] as? FlutterStandardTypedData,
                let frame = args["frame"] as? Int, let width = args["width"] as? Int, let height = args["height"] as? Int
          else { throw EncoderError.failed("Bad frame.") }
          try session.append(rgba.data, frame: frame, width: width, height: height)
          reply = nil
        case "finish":
          guard let id = args["id"] as? Int, let session = self.sessions.removeValue(forKey: id)
          else { throw EncoderError.failed("No such render.") }
          let (path, bytes) = try session.finish()
          reply = ["path": path, "bytes": bytes]
        case "cancel":
          if let id = args["id"] as? Int { self.sessions.removeValue(forKey: id)?.cancel() }
          reply = nil
        default:
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
      } catch let error as EncoderError {
        if let id = args["id"] as? Int, call.method == "append" { self.sessions.removeValue(forKey: id)?.cancel() }
        DispatchQueue.main.async { result(FlutterError(code: error.code, message: error.message, details: nil)) }
        return
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "failed", message: error.localizedDescription, details: nil)) }
        return
      }
      DispatchQueue.main.async { result(reply) }
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    audioJobs.values.forEach { $0.cancel() }
    audioJobs.removeAll()
    queue.async { self.sessions.values.forEach { $0.cancel() }; self.sessions.removeAll() }
  }

  private func session(_ args: [String: Any]) -> EncodeSession? {
    guard let id = args["id"] as? Int else { return nil }
    return sessions[id]
  }

  // MARK: - Capabilities

  /// A codec is offered only if VideoToolbox lists an encoder for it and
  /// AVAssetWriter accepts it at that size — so ProRes shows only on the
  /// iPhones and iPads that can make it.
  private static func capabilities() -> [String: Any] {
    var encoders: CFArray?
    VTCopyVideoEncoderList(nil, &encoders)
    let types = Set(((encoders as NSArray?) as? [[String: Any]] ?? []).compactMap {
      ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value
    })

    var codecs: [String: Int] = [:]
    for codec in EncoderCodec.allCases where types.contains(codec.fourCC) {
      if let edge = [3840, 1920, 1280].first(where: { codec.canEncode(width: $0, height: $0 * 9 / 16) }) {
        codecs[codec.rawValue] = edge
      }
    }

    var result: [String: Any] = ["codecs": codecs]
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    if let free = try? tmp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage {
      result["freeBytes"] = free
    }
    return result
  }
}

// MARK: - Codecs

private enum EncoderCodec: String, CaseIterable {
  case h264, hevc, prores422, prores4444

  var avCodec: AVVideoCodecType {
    switch self {
    case .h264: return .h264
    case .hevc: return .hevc
    case .prores422: return .proRes422HQ
    case .prores4444: return .proRes4444
    }
  }

  var fourCC: CMVideoCodecType {
    switch self {
    case .h264: return kCMVideoCodecType_H264
    case .hevc: return kCMVideoCodecType_HEVC
    case .prores422: return kCMVideoCodecType_AppleProRes422HQ
    case .prores4444: return kCMVideoCodecType_AppleProRes4444
    }
  }

  var fileType: AVFileType { self == .h264 || self == .hevc ? .mp4 : .mov }

  func settings(width: Int, height: Int, fps: Double, bitrate: Int) -> [String: Any] {
    var settings: [String: Any] = [
      AVVideoCodecKey: avCodec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      // Credits are graphics made in sRGB; tag them Rec. 709 like any HD master.
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    switch self {
    case .h264, .hevc:
      var compression: [String: Any] = [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: max(1, Int((fps * 2).rounded())),
      ]
      if self == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
      settings[AVVideoCompressionPropertiesKey] = compression
    case .prores422, .prores4444:
      break
    }
    return settings
  }

  func canEncode(width: Int, height: Int, fps: Double = 30) -> Bool {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("probe-\(UUID().uuidString).\(self == .h264 || self == .hevc ? "mp4" : "mov")")
    defer { try? FileManager.default.removeItem(at: url) }
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: fileType) else { return false }
    return writer.canApply(outputSettings: settings(width: width, height: height, fps: fps, bitrate: 10_000_000), forMediaType: .video)
  }
}

// MARK: - Errors

private enum EncoderError: Error {
  case outOfSpace
  case unsupported(String)
  case failed(String)

  var code: String {
    switch self {
    case .outOfSpace: return "out_of_space"
    case .unsupported: return "unsupported"
    case .failed: return "failed"
    }
  }

  var message: String {
    switch self {
    case .outOfSpace: return "Not enough free space."
    case .unsupported(let m), .failed(let m): return m
    }
  }

  /// AVFoundation reports a full disk several ways; all of them are the
  /// one cause 6.3 designs for.
  static func from(_ error: Error?) -> EncoderError {
    guard let error = error as NSError? else { return .failed("The encoder stopped.") }
    if isOutOfSpace(error) { return .outOfSpace }
    return .failed(error.localizedDescription)
  }

  private static func isOutOfSpace(_ error: NSError) -> Bool {
    if error.domain == AVFoundationErrorDomain && error.code == AVError.diskFull.rawValue { return true }
    if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) { return true }
    if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError { return true }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
    return false
  }
}

// MARK: - A session

private final class EncodeSession {
  private let url: URL
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let width: Int
  private let height: Int
  private let fpsNum: Int32
  private let fpsDen: Int64
  private var lastFrame: Int = -1

  init(_ args: [String: Any]) throws {
    guard let name = args["codec"] as? String, let codec = EncoderCodec(rawValue: name) else {
      throw EncoderError.unsupported("This device can’t encode that codec.")
    }
    guard let width = args["width"] as? Int, let height = args["height"] as? Int,
          let fpsNum = args["fpsNum"] as? Int, let fpsDen = args["fpsDen"] as? Int,
          let path = args["path"] as? String
    else { throw EncoderError.failed("Bad render settings.") }
    let bitrate = args["bitrate"] as? Int ?? 0

    self.url = URL(fileURLWithPath: path)
    self.width = width
    self.height = height
    self.fpsNum = Int32(fpsNum)
    self.fpsDen = Int64(fpsDen)

    try? FileManager.default.removeItem(at: url)
    do {
      writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)
    } catch {
      throw EncoderError.from(error)
    }
    let settings = codec.settings(width: width, height: height, fps: Double(fpsNum) / Double(fpsDen), bitrate: bitrate)
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
      throw EncoderError.unsupported("This device can’t encode \(width) × \(height) in that codec.")
    }
    input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    // Keep NTSC frame durations exact instead of rounding to the default 600 ticks.
    input.mediaTimeScale = self.fpsNum
    writer.movieTimeScale = self.fpsNum
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      ]
    )
    writer.add(input)
    guard writer.startWriting() else { throw EncoderError.from(writer.error) }
    writer.startSession(atSourceTime: .zero)
  }

  /// Takes premultiplied RGBA from Flutter, swizzles it into a BGRA pixel
  /// buffer and stamps it with its own time: frame × den / num seconds.
  func append(_ rgba: Data, frame: Int, width: Int, height: Int) throws {
    guard width == self.width, height == self.height, rgba.count >= width * height * 4 else {
      throw EncoderError.failed("A frame came in at the wrong size.")
    }
    let deadline = Date().addingTimeInterval(30)
    while !input.isReadyForMoreMediaData {
      if Date() > deadline { throw EncoderError.failed("Video encoder timed out.") }
      if writer.status == .failed { throw EncoderError.from(writer.error) }
      usleep(2_000)
    }
    guard let pool = adaptor.pixelBufferPool else { throw EncoderError.from(writer.error) }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer else {
      throw EncoderError.failed("Out of memory for a frame.")
    }

    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let swizzled: vImage_Error = rgba.withUnsafeBytes { raw in
      var source = vImage_Buffer(
        data: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
        height: vImagePixelCount(height),
        width: vImagePixelCount(width),
        rowBytes: width * 4
      )
      var destination = vImage_Buffer(
        data: CVPixelBufferGetBaseAddress(pixels),
        height: vImagePixelCount(height),
        width: vImagePixelCount(width),
        rowBytes: CVPixelBufferGetBytesPerRow(pixels)
      )
      let rgbaToBgra: [UInt8] = [2, 1, 0, 3]
      return vImagePermuteChannels_ARGB8888(&source, &destination, rgbaToBgra, vImage_Flags(kvImageNoFlags))
    }
    guard swizzled == kvImageNoError else { throw EncoderError.failed("A frame couldn’t be converted.") }

    let time = CMTime(value: Int64(frame) * fpsDen, timescale: fpsNum)
    guard adaptor.append(pixels, withPresentationTime: time) else { throw EncoderError.from(writer.error) }
    lastFrame = frame
  }

  func finish() throws -> (String, Int) {
    guard lastFrame >= 0 else { cancel(); throw EncoderError.failed("No frames were submitted.") }
    writer.endSession(atSourceTime: CMTime(value: Int64(lastFrame + 1) * fpsDen, timescale: fpsNum))
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    guard done.wait(timeout: .now() + 30) == .success else {
      cancel(); throw EncoderError.failed("Finalizing video timed out.")
    }
    guard writer.status == .completed else {
      let error = EncoderError.from(writer.error)
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    return (url.path, bytes)
  }

  func cancel() {
    if writer.status == .writing { writer.cancelWriting() }
    try? FileManager.default.removeItem(at: url)
  }
}
