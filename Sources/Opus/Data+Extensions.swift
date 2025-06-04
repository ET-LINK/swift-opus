import AVFoundation
import Foundation

extension Data {
	/// 从 AVAudioPCMBuffer 创建 PCM 格式的 Data
	/// - Parameter buffer: 要转换的音频缓冲区
	/// - Throws: 如果缓冲区格式不支持或转换失败则抛出错误
	public init(pcmBuffer buffer: AVAudioPCMBuffer) throws {
				guard let channelData = buffer.floatChannelData else {
			throw Opus.Error.badArgument
		}

		guard buffer.format.isValidOpusPCMFormat else {
			throw Opus.Error.badArgument
		}

		let frameLength = Int(buffer.frameLength)
		let channelCount = Int(buffer.format.channelCount)

		// 边界检查：确保 frameLength 和 channelCount 都大于 0
		guard frameLength > 0, channelCount > 0 else {
			throw Opus.Error.badArgument
		}

		switch buffer.format.commonFormat {
		case .pcmFormatFloat32:
			// Float32 PCM 数据
			if buffer.format.isInterleaved {
				// 交错格式
				let dataSize = frameLength * channelCount * MemoryLayout<Float>.size
				self.init(count: dataSize)
				self.withUnsafeMutableBytes { bytes in
					let floatPtr = bytes.bindMemory(to: Float.self)
					let sourcePtr = channelData[0]
					for i in 0..<frameLength * channelCount {
						floatPtr[i] = sourcePtr[i]
					}
				}
			} else {
				// 非交错格式，需要交错排列
				let dataSize = frameLength * channelCount * MemoryLayout<Float>.size
				self.init(count: dataSize)
				self.withUnsafeMutableBytes { bytes in
					let floatPtr = bytes.bindMemory(to: Float.self)
					for frame in 0..<frameLength {
						for channel in 0..<channelCount {
							floatPtr[frame * channelCount + channel] = channelData[channel][frame]
						}
					}
				}
			}
		case .pcmFormatInt16:
			// Int16 PCM 数据
			if buffer.format.isInterleaved {
				// 交错格式
				let dataSize = frameLength * channelCount * MemoryLayout<Int16>.size
				self.init(count: dataSize)
				self.withUnsafeMutableBytes { bytes in
					let int16Ptr = bytes.bindMemory(to: Int16.self)
					let sourcePtr = UnsafeRawPointer(channelData[0]).bindMemory(to: Int16.self, capacity: frameLength * channelCount)
					for i in 0..<frameLength * channelCount {
						int16Ptr[i] = sourcePtr[i]
					}
				}
			} else {
				// 非交错格式，需要交错排列
				let dataSize = frameLength * channelCount * MemoryLayout<Int16>.size
				self.init(count: dataSize)
				self.withUnsafeMutableBytes { bytes in
					let int16Ptr = bytes.bindMemory(to: Int16.self)
					for frame in 0..<frameLength {
						for channel in 0..<channelCount {
							let channelPtr = UnsafeRawPointer(channelData[channel]).bindMemory(to: Int16.self, capacity: frameLength)
							int16Ptr[frame * channelCount + channel] = channelPtr[frame]
						}
					}
				}
			}
		default:
			throw Opus.Error.badArgument
		}
	}

	/// 从 Float32 格式的 AVAudioPCMBuffer 创建 Int16 格式的 PCM Data
	/// - Parameter buffer: Float32 格式的音频缓冲区
	/// - Throws: 如果缓冲区格式不是 Float32 或转换失败则抛出错误
	public init(float32PCMBuffer buffer: AVAudioPCMBuffer) throws {
		guard buffer.format.commonFormat == .pcmFormatFloat32 else {
			throw Opus.Error.badArgument
		}

		guard let channelData = buffer.floatChannelData else {
			throw Opus.Error.badArgument
		}

		let frameLength = Int(buffer.frameLength)
		let channelCount = Int(buffer.format.channelCount)

		// 边界检查：确保 frameLength 和 channelCount 都大于 0
		guard frameLength > 0, channelCount > 0 else {
			throw Opus.Error.badArgument
		}

		// Int16 格式的数据大小
		let dataSize = frameLength * channelCount * MemoryLayout<Int16>.size
		self.init(count: dataSize)

		self.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
			let int16Ptr = bytes.bindMemory(to: Int16.self).baseAddress!

			if buffer.format.isInterleaved {
				// 交错格式：直接转换
				let sourcePtr = channelData[0]
				for i in 0..<frameLength * channelCount {
					let floatValue = sourcePtr[i]
					// 将 Float32 (-1.0 到 1.0) 转换为 Int16 (-32768 到 32767)
					// 使用剪裁防止溢出
					let clampedValue = Swift.max(-1.0, Swift.min(1.0, floatValue))
					let int16Value = Int16(clampedValue * 32767.0)
					int16Ptr[i] = int16Value
				}
			} else {
				// 非交错格式：转换为交错排列的 Int16
				for frame in 0..<frameLength {
					for channel in 0..<channelCount {
						let floatValue = channelData[channel][frame]
						// 将 Float32 (-1.0 到 1.0) 转换为 Int16 (-32768 到 32767)
						// 使用剪裁防止溢出
						let clampedValue = Swift.max(-1.0, Swift.min(1.0, floatValue))
						let int16Value = Int16(clampedValue * 32767.0)
						int16Ptr[frame * channelCount + channel] = int16Value
					}
				}
			}
		}
	}
}

extension Data {
	/// 将 PCM Data 转换为 AVAudioPCMBuffer
	/// - Parameters:
	///   - format: 目标音频格式
	///   - frameCapacity: 缓冲区帧容量（如果为 nil，则根据数据大小计算）
	/// - Returns: 转换后的 AVAudioPCMBuffer
	/// - Throws: 如果格式不支持或转换失败则抛出错误
	public func toAVAudioPCMBuffer(format: AVAudioFormat, frameCapacity: AVAudioFrameCount? = nil) throws -> AVAudioPCMBuffer {
		guard format.isValidOpusPCMFormat else {
			throw Opus.Error.badArgument
		}

		let channelCount = Int(format.channelCount)
		let bytesPerSample: Int

		switch format.commonFormat {
		case .pcmFormatFloat32:
			bytesPerSample = MemoryLayout<Float>.size
		case .pcmFormatInt16:
			bytesPerSample = MemoryLayout<Int16>.size
		default:
			throw Opus.Error.badArgument
		}

		let calculatedFrameCapacity = AVAudioFrameCount(self.count / (channelCount * bytesPerSample))
		let actualFrameCapacity = frameCapacity ?? calculatedFrameCapacity

		guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: actualFrameCapacity) else {
			throw Opus.Error.badArgument
		}

		guard let channelData = buffer.floatChannelData else {
			throw Opus.Error.badArgument
		}

		buffer.frameLength = calculatedFrameCapacity

		self.withUnsafeBytes { bytes in
			switch format.commonFormat {
			case .pcmFormatFloat32:
				let sourcePtr = bytes.bindMemory(to: Float.self)
				if format.isInterleaved {
					// 交错格式
					let destPtr = channelData[0]
					for i in 0..<Int(calculatedFrameCapacity) * channelCount {
						destPtr[i] = sourcePtr[i]
					}
				} else {
					// 非交错格式
					for frame in 0..<Int(calculatedFrameCapacity) {
						for channel in 0..<channelCount {
							channelData[channel][frame] = sourcePtr[frame * channelCount + channel]
						}
					}
				}
			case .pcmFormatInt16:
				let sourcePtr = bytes.bindMemory(to: Int16.self)
				if format.isInterleaved {
					// 交错格式
					let destPtr = UnsafeMutableRawPointer(channelData[0]).bindMemory(to: Int16.self, capacity: Int(calculatedFrameCapacity) * channelCount)
					for i in 0..<Int(calculatedFrameCapacity) * channelCount {
						destPtr[i] = sourcePtr[i]
					}
				} else {
					// 非交错格式
					for frame in 0..<Int(calculatedFrameCapacity) {
						for channel in 0..<channelCount {
							let destPtr = UnsafeMutableRawPointer(channelData[channel]).bindMemory(to: Int16.self, capacity: Int(calculatedFrameCapacity))
							destPtr[frame] = sourcePtr[frame * channelCount + channel]
						}
					}
				}
			default:
				break
			}
		}

		return buffer
	}
}
