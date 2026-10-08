import AVFoundation
import Photos
import CoreImage

/// 停止录制后一次性合成：JPEG 帧序列 → HEVC 30fps 视频 → 系统相册
enum ComposerError: Error {
    case noFrames
    case writerFailed
    case photoLibraryDenied
}

final class TimelapseComposer {

    static func compose(frameURLs: [URL], fps: Int32 = 30,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard let firstURL = frameURLs.first,
              let firstImage = CIImage(contentsOf: firstURL) else {
            completion(.failure(ComposerError.noFrames))
            return
        }

        let width = Int(firstImage.extent.width)
        let height = Int(firstImage.extent.height)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SunriseLapse-\(UUID().uuidString).mov")

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false

            let sourceAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input, sourcePixelBufferAttributes: sourceAttrs)

            guard writer.canAdd(input) else { throw ComposerError.writerFailed }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? ComposerError.writerFailed }
            writer.startSession(atSourceTime: .zero)

            let ciContext = CIContext()
            let queue = DispatchQueue(label: "com.sunriselapse.composer")
            var index = 0

            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if index >= frameURLs.count {
                        input.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                saveToPhotos(outputURL: outputURL, completion: completion)
                            } else {
                                try? FileManager.default.removeItem(at: outputURL)
                                completion(.failure(writer.error ?? ComposerError.writerFailed))
                            }
                        }
                        return
                    }

                    autoreleasepool {
                        let pts = CMTime(value: CMTimeValue(index), timescale: fps)
                        if let image = CIImage(contentsOf: frameURLs[index]),
                           let pool = adaptor.pixelBufferPool {
                            var pixelBuffer: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                            if let pixelBuffer {
                                ciContext.render(image, to: pixelBuffer)
                                adaptor.append(pixelBuffer, withPresentationTime: pts)
                            }
                        }
                    }
                    index += 1
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private static func saveToPhotos(outputURL: URL,
                                     completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: outputURL)
                completion(.failure(ComposerError.photoLibraryDenied))
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
            }) { _, error in
                try? FileManager.default.removeItem(at: outputURL)
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(()))
                }
            }
        }
    }
}
