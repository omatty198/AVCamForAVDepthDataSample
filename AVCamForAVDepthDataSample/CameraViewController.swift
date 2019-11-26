//
//  CameraViewController.swift
//  AVCamForAVDepthDataSample
//
//  Created by omatty198 on 2019/11/17.
//  Copyright © 2019 omatty198. All rights reserved.
//

import UIKit
import AVFoundation
import Photos

final class CameraViewController: UIViewController {
    
    @IBOutlet private weak var previewView: PreviewView!
    @IBOutlet private weak var photoButton: UIButton!
    
    @objc dynamic var videoDeviceInput: AVCaptureDeviceInput!
    
    private var inProgressPhotoCaptureDelegates = [Int64: PhotoCaptureProcessor]()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "session queue") // Communicate with the session and other session objects on this queue.
    private let photoOutput = AVCapturePhotoOutput()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        configure()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async {
            self.session.startRunning()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        sessionQueue.async {
            self.session.stopRunning()
        }
        super.viewWillDisappear(animated)
    }
}

// MARK: - About private func
extension CameraViewController {
    private func configure() {
        previewView.session = session
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
            
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted { fatalError() }
                self.sessionQueue.resume()
            })
            
        default:
            fatalError()
        }
        
        sessionQueue.async {
            self.configureSession()
        }
    }
    
    private func configureSession() {
        session.beginConfiguration()
        
        /*
         We do not create an AVCaptureMovieFileOutput when setting up the session because
         Live Photo is not supported when AVCaptureMovieFileOutput is added to the session.
         */
        session.sessionPreset = .photo
        
        // Add video input.
        var defaultVideoDevice: AVCaptureDevice?
        
        // Choose the back dual camera if available, otherwise default to a wide angle camera.
        if let dualCameraDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            defaultVideoDevice = dualCameraDevice
        } else if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            // If a rear dual camera is not available, default to the rear wide angle camera.
            defaultVideoDevice = backCameraDevice
        } else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            // In the event that the rear wide angle camera isn't available, default to the front wide angle camera.
            defaultVideoDevice = frontCameraDevice
        }
        guard let videoDevice = defaultVideoDevice else { fatalError() }
        let videoDeviceInput = try! AVCaptureDeviceInput(device: videoDevice)
        
        guard session.canAddInput(videoDeviceInput)  else { fatalError() }
        session.addInput(videoDeviceInput)
        self.videoDeviceInput = videoDeviceInput
        
        DispatchQueue.main.async {
            let initialVideoOrientation: AVCaptureVideoOrientation = .portrait
            self.previewView.videoPreviewLayer.connection?.videoOrientation = initialVideoOrientation
        }

        // Add photo output.
        guard session.canAddOutput(photoOutput) else { fatalError() }
        session.addOutput(photoOutput)
        // NOTE: - Step1
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        // Needed to crash
        photoOutput.isHighResolutionCaptureEnabled = true

        session.commitConfiguration()
    }

}

// MARK: - About Buttons
extension CameraViewController {
    @IBAction private func capturePhoto(_ photoButton: UIButton) {
        /*
         Retrieve the video preview layer's video orientation on the main queue before
         entering the session queue. We do this to ensure UI elements are accessed on
         the main thread and session configuration is done on the session queue.
         */
        let videoPreviewLayerOrientation = previewView.videoPreviewLayer.connection?.videoOrientation
        
        sessionQueue.async {
            if let photoOutputConnection = self.photoOutput.connection(with: .video) {
                photoOutputConnection.videoOrientation = videoPreviewLayerOrientation!
            }
            var photoSettings = AVCapturePhotoSettings()
            
            // Capture HEIF photos when supported. Enable auto-flash and high-resolution photos.
            if  self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }
            
            if self.videoDeviceInput.device.isFlashAvailable {
                photoSettings.flashMode = .auto
            }
            
            photoSettings.isHighResolutionPhotoEnabled = true
            if !photoSettings.__availablePreviewPhotoPixelFormatTypes.isEmpty {
                photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes.first!]
            }
            
            photoSettings.isDepthDataDeliveryEnabled = true
            
            let photoCaptureProcessor = PhotoCaptureProcessor(with: photoSettings, willCapturePhotoAnimation: {
                // Flash the screen to signal that AVCam took a photo.
                DispatchQueue.main.async {
                    self.previewView.videoPreviewLayer.opacity = 0
                    UIView.animate(withDuration: 0.25) {
                        self.previewView.videoPreviewLayer.opacity = 1
                    }
                }
            }, completionHandler: { photoCaptureProcessor in
                // When the capture is complete, remove a reference to the photo capture delegate so it can be deallocated.
                self.sessionQueue.async {
                    self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = nil
                }
            })
            
            // The photo output keeps a weak reference to the photo capture delegate and stores it in an array to maintain a strong reference.
            self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = photoCaptureProcessor
            self.photoOutput.capturePhoto(with: photoSettings, delegate: photoCaptureProcessor)
        }
    }
}
