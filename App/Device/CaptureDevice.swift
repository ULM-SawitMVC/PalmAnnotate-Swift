@preconcurrency import AVFoundation
import CoreLocation
import PalmCore
import SwiftUI
import UIKit

enum CaptureError: LocalizedError {
    case camera, microphone, photo, video, recordingInterrupted

    var errorDescription: String? {
        switch self {
        case .camera: "Kamera belakang tidak tersedia atau izinnya ditolak."
        case .microphone: "Izinkan mikrofon untuk merekam video dengan audio."
        case .photo: "Foto tidak dapat dibaca."
        case .video: "Video dengan audio tidak dapat disimpan."
        case .recordingInterrupted: "Rekaman terhenti. Mulai ulang rekaman untuk menyimpan sampel."
        }
    }
}

final class CaptureDevice: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.sawitulm.palmannotate.capture")
    private let photos = AVCapturePhotoOutput()
    private let movies = AVCaptureMovieFileOutput()
    private var photoContinuation: CheckedContinuation<Data, Error>?
    private var videoStart: CheckedContinuation<Void, Error>?
    private var videoStop: CheckedContinuation<URL, Error>?
    private var recordingURL: URL?
    private var recordingInterrupted: (@MainActor @Sendable () -> Void)?
    private var configured = false

    func start(withVideo: Bool) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CaptureError.camera }
        if withVideo {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CaptureError.microphone }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if !self.configured { try self.configure(withVideo: withVideo) }
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configure(withVideo: Bool) throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.camera
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CaptureError.camera }
        session.addInput(input)
        do {
            if withVideo {
                guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.microphone }
                let audio = try AVCaptureDeviceInput(device: microphone)
                guard session.canAddInput(audio) else { throw CaptureError.microphone }
                session.addInput(audio)
            }
            let preset: AVCaptureSession.Preset = withVideo ? .high : .photo
            if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
            guard session.canAddOutput(photos) else { throw CaptureError.camera }
            session.addOutput(photos)
            if withVideo {
                guard session.canAddOutput(movies) else { throw CaptureError.video }
                session.addOutput(movies)
            }
            configured = true
        } catch {
            session.outputs.forEach(session.removeOutput)
            session.inputs.forEach(session.removeInput)
            throw error
        }
    }

    func stop() {
        queue.async {
            self.recordingInterrupted = nil
            if self.movies.isRecording { self.movies.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func takePhoto(rotation: CGFloat) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning, self.photoContinuation == nil else {
                    continuation.resume(throwing: CaptureError.camera)
                    return
                }
                self.photoContinuation = continuation
                self.setRotation(self.photos.connection(with: .video), angle: rotation)
                self.photos.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
            }
        }
    }

    func startVideo(rotation: CGFloat, onInterruption: (@MainActor @Sendable () -> Void)? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.session.isRunning, self.recordingURL == nil,
                      let connection = self.movies.connection(with: .video) else {
                    continuation.resume(throwing: CaptureError.video)
                    return
                }
                self.setRotation(connection, angle: rotation)
                if self.movies.availableVideoCodecTypes.contains(.h264) {
                    self.movies.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                }
                self.videoStart = continuation
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                self.recordingURL = url
                self.recordingInterrupted = onInterruption
                self.movies.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    func finishVideo() async throws -> URL {
        let movie: URL = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.movies.isRecording, self.videoStop == nil else {
                    continuation.resume(throwing: CaptureError.recordingInterrupted)
                    return
                }
                self.videoStop = continuation
                self.movies.stopRecording()
            }
        }
        defer { try? FileManager.default.removeItem(at: movie) }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        do {
            let asset = AVURLAsset(url: movie)
            guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
                  exporter.supportedFileTypes.contains(.mp4) else { throw CaptureError.video }
            if #available(iOS 18, *) {
                try await exporter.export(to: target, as: .mp4)
            } else {
                exporter.outputURL = target
                exporter.outputFileType = .mp4
                await exporter.export()
                guard exporter.status == .completed else { throw exporter.error ?? CaptureError.video }
            }
            let exported = AVURLAsset(url: target)
            let audio = try await exported.loadTracks(withMediaType: .audio)
            let video = try await exported.loadTracks(withMediaType: .video)
            guard !audio.isEmpty, !video.isEmpty else { throw CaptureError.video }
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        queue.async {
            let caller = self.photoContinuation
            self.photoContinuation = nil
            if let error { caller?.resume(throwing: error) }
            else if let data { caller?.resume(returning: data) }
            else { caller?.resume(throwing: CaptureError.photo) }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async {
            guard fileURL == self.recordingURL else { return }
            let caller = self.videoStart
            self.videoStart = nil
            caller?.resume()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard fileURL == self.recordingURL else { return }
            let start = self.videoStart
            self.videoStart = nil
            let caller = self.videoStop
            self.videoStop = nil
            let interrupted = self.recordingInterrupted
            self.recordingInterrupted = nil
            self.recordingURL = nil
            start?.resume(throwing: error ?? CaptureError.recordingInterrupted)
            if let caller, error == nil {
                caller.resume(returning: fileURL)
            } else {
                try? FileManager.default.removeItem(at: fileURL)
                caller?.resume(throwing: error ?? CaptureError.recordingInterrupted)
                if start == nil, caller == nil, let interrupted { Task { await interrupted() } }
            }
        }
    }

    private func setRotation(_ connection: AVCaptureConnection?, angle: CGFloat) {
        if let connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CaptureDevice

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = camera.session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) { view.setNeedsLayout() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = preview.connection, let scene = window?.windowScene else { return }
            let rotation = Self.rotation(for: scene.interfaceOrientation)
            if connection.isVideoRotationAngleSupported(rotation) { connection.videoRotationAngle = rotation }
        }

        static func rotation(for orientation: UIInterfaceOrientation) -> CGFloat {
            switch orientation {
            case .landscapeLeft: 0
            case .landscapeRight: 180
            case .portraitUpsideDown: 270
            default: 90
            }
        }
    }
}

@MainActor
final class CaptureLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var provenance = Provenance(status: .unavailable)

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func refresh() {
        provenance = Provenance(status: .unavailable)
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: provenance = Provenance(status: .permissionDenied)
        @unknown default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined { refresh() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let current = locations.last, current.horizontalAccuracy >= 0 else { return }
        let milliseconds = Int64(current.timestamp.timeIntervalSince1970 * 1000)
        let now = Date.now
        let age = now.timeIntervalSince(current.timestamp)
        provenance = Provenance(status: (0...60).contains(age) ? .fresh : .stale,
            latitude: current.coordinate.latitude, longitude: current.coordinate.longitude,
            accuracyM: current.horizontalAccuracy, fixTimeMillis: milliseconds,
            provider: "corelocation", source: age > 60 ? "LAST_KNOWN" : "CURRENT_FIX").atCommit(now)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        provenance = Provenance(status: manager.authorizationStatus == .denied ? .permissionDenied : .unavailable)
    }
}

@MainActor
func normalizedPhoto(_ data: Data) throws -> CapturedPhoto {
    guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { throw CaptureError.photo }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
    let bytes = renderer.jpegData(withCompressionQuality: 0.94) { _ in image.draw(at: .zero) }
    return CapturedPhoto(jpeg: bytes, width: Int(image.size.width), height: Int(image.size.height))
}
