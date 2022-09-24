//
//  ViewController.swift
//  FaceDetector
//
//  Created by Heitor Novais on 24/09/22.
//

import Foundation
import UIKit
import AVFoundation
import MLImage
import MLKit

class ViewController: UIViewController {

    // MARK: Views

    @IBOutlet weak var faceStatusLabel: UILabel!
    @IBOutlet weak var paramsStackView: UIStackView!
    @IBOutlet weak var rotXLabel: UILabel!
    @IBOutlet weak var rotYLabel: UILabel!
    @IBOutlet weak var rotZLabel: UILabel!
    @IBOutlet weak var smilingProbLabel: UILabel!

    private lazy var rectView: UIView = {
        let rectView = UIView()
        rectView.layer.borderColor = UIColor.yellow.cgColor
        rectView.layer.borderWidth = 1
        return rectView
    }()

    // MARK: AVCapture components

    private var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    private var captureSession = AVCaptureSession()

    // MARK: Properties

    private var sessionQueue = DispatchQueue(label: SelfieQueue.sessionLabel)

    // MARK: Life cycle methdos

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupCaptureSessionOutput()
        setupCaptureSessionInput()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        videoPreviewLayer.frame = view.frame
    }

    // MARK: Methods

    private func setupUI() {
        videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoPreviewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(videoPreviewLayer)
        view.addSubview(rectView)
        view.bringSubviewToFront(rectView)
        view.bringSubviewToFront(faceStatusLabel)
        view.bringSubviewToFront(paramsStackView)
        view.bringSubviewToFront(rotYLabel)
        view.bringSubviewToFront(rotZLabel)
        view.bringSubviewToFront(smilingProbLabel)
    }

    private func setupCaptureSessionOutput() {
        sessionQueue.async { [weak self] in
            self?.captureSession.beginConfiguration()
            self?.captureSession.sessionPreset = AVCaptureSession.Preset.high

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [(kCVPixelBufferPixelFormatTypeKey as String): kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            let outputQueue = DispatchQueue(label: SelfieQueue.videoDataOutputLabel)
            output.setSampleBufferDelegate(self, queue: outputQueue)

            guard self?.captureSession.canAddOutput(output) ?? false else {
                print("Failed to add capture session output.")
                return
            }
            self?.captureSession.addOutput(output)

            self?.captureSession.commitConfiguration()
        }
    }

    private func setupCaptureSessionInput() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            guard let device = self.captureDevice(forPosition: AVCaptureDevice.Position.front) else {
                print("Failed to get capture device for camera position: \(AVCaptureDevice.Position.front)")
                return
            }

            do {
                self.captureSession.beginConfiguration()

                for input in self.captureSession.inputs {
                    self.captureSession.removeInput(input)
                }

                let input = try AVCaptureDeviceInput(device: device)
                guard self.captureSession.canAddInput(input) else {
                    print("Failed to add capture session input.")
                    return
                }
                self.captureSession.addInput(input)

                self.captureSession.commitConfiguration()
            } catch {
                print("Failed to create capture device input: \(error.localizedDescription)")
            }
        }
    }

    private func captureDevice(forPosition position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices.first { $0.position == position }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    private func stopSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }
}

// MARK: Methods of AVCaptureVideoDataOutputSampleBufferDelegate

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Failed to get image buffer from sample buffer.")
            return
        }

        let visionImage = VisionImage(buffer: sampleBuffer)
        let orientation = UIHelper.imageOrientation(fromDevicePosition: .front)
        visionImage.orientation = orientation

        guard let inputImage = MLImage(sampleBuffer: sampleBuffer) else {
            print("Failed to create MLImage from sample buffer.")
            return
        }
        inputImage.orientation = orientation

        let imageWidth = CGFloat(CVPixelBufferGetWidth(imageBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(imageBuffer))
        detectFacesOnDevice(in: visionImage, width: imageWidth, height: imageHeight)
    }

    private func detectFacesOnDevice(in image: VisionImage, width: CGFloat, height: CGFloat) {
        let options = FaceDetectorOptions()
        options.landmarkMode = .all
        options.contourMode = .all
        options.classificationMode = .all
        options.performanceMode = .accurate

        let faceDetector = FaceDetector.faceDetector(options: options)
        var faces: [Face] = []
        var detectionError: Error?
        do {
            faces = try faceDetector.results(in: image)
        } catch let error {
            detectionError = error
        }

        DispatchQueue.main.sync { [weak self] in
            if let detectionError = detectionError {
                print("Failed to detect faces with error: \(detectionError.localizedDescription).")
                return
            }

            guard !faces.isEmpty else {
                print("On-Device face detector returned no results.")
                self?.updateRectViewFrame(.zero)
                return
            }

            for face in faces {
                let normalizedRect = CGRect(
                    x: face.frame.origin.x / width,
                    y: face.frame.origin.y / height,
                    width: face.frame.size.width / width,
                    height: face.frame.size.height / height
                )
                
                self?.updateRectViewFrame(normalizedRect)
                self?.updateFaceParameterLabels(face)
                self?.recognizeFaceStatus(face)
            }
        }
    }

    private func updateRectViewFrame(_ normalizedRect: CGRect) {
        let standardizedRect = videoPreviewLayer.layerRectConverted(
            fromMetadataOutputRect: normalizedRect
        ).standardized
        rectView.frame = standardizedRect
    }

    private func updateFaceParameterLabels(_ face: Face) {
        rotXLabel.text = "RotX: \(face.headEulerAngleX.rounded(toPlaces: 2))"
        rotYLabel.text = "RotY: \(face.headEulerAngleY.rounded(toPlaces: 2))"
        rotZLabel.text = "RotZ: \(face.headEulerAngleZ.rounded(toPlaces: 2))"
        smilingProbLabel.text = "Smiling Prob.: \(face.smilingProbability.rounded(toPlaces: 2))"

        debugPrint("RotX: \(face.headEulerAngleX)\n" +
                   "RotY: \(face.headEulerAngleY)\n" +
                   "RotZ: \(face.headEulerAngleZ )\n" +
                   "Smiling Prob.: \(face.smilingProbability)")
    }

    private func recognizeFaceStatus(_ face: Face) {
        var status = [FaceStatus]()

        if face.headEulerAngleX >= 18.0 {
            status.append(.faceUp)
        }

        if face.headEulerAngleX <= -18.0 {
            status.append(.faceDown)
        }

        if face.headEulerAngleY >= 35.0 {
            status.append(.faceRigth)
        }

        if face.headEulerAngleY <= -35.0 {
            status.append(.faceLeft)
        }

        if face.smilingProbability >= 0.95 {
            status.append(.faceSmiling)
        }

        faceStatusLabel.text = status.map { $0.rawValue }.reduce("") { $0 + (!$0.isEmpty ? ", " : "") + $1 }
    }
}
