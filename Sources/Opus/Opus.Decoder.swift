import AVFoundation
import Copus
import CoreMedia

extension Opus {
	public class Decoder {
		let format: AVAudioFormat
		let decoder: OpaquePointer

		// TODO: throw an error if format is unsupported
		public init(format: AVAudioFormat, application _: Application = .audio) throws {
			if !format.isValidOpusPCMFormat {
				throw Opus.Error.badArgument
			}

			self.format = format

			// Initialize Opus decoder
			var error: Opus.Error = .ok
			decoder = opus_decoder_create(Int32(format.sampleRate), Int32(format.channelCount), &error.rawValue)
			if error != .ok {
				throw error
			}
		}

		deinit {
			opus_decoder_destroy(decoder)
		}

		public func reset() throws {
			let error = Opus.Error(opus_decoder_init(decoder, Int32(format.sampleRate), Int32(format.channelCount)))
			if error != .ok {
				throw error
			}
		}
	}
}

// MARK: Public decode methods

extension Opus.Decoder {
	public func decode(_ input: Data) throws -> AVAudioPCMBuffer {
		try input.withUnsafeBytes {
			let input = $0.bindMemory(to: UInt8.self)
			let sampleCount = opus_decoder_get_nb_samples(decoder, input.baseAddress!, Int32($0.count))
			if sampleCount < 0 {
				throw Opus.Error(sampleCount)
			}
			let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))!
			try decode(input, to: output)
			return output
		}
	}

	public func decode(_ input: UnsafeBufferPointer<UInt8>, to output: AVAudioPCMBuffer) throws {
		let decodedCount: Int
		switch output.format.commonFormat {
		case .pcmFormatInt16:
			let output = UnsafeMutableBufferPointer(start: output.int16ChannelData![0], count: Int(output.frameCapacity))
			decodedCount = try decode(input, to: output)
		case .pcmFormatFloat32:
			let output = UnsafeMutableBufferPointer(start: output.floatChannelData![0], count: Int(output.frameCapacity))
			decodedCount = try decode(input, to: output)
		default:
			throw Opus.Error.badArgument
		}
		if decodedCount < 0 {
			throw Opus.Error(decodedCount)
		}
		output.frameLength = AVAudioFrameCount(decodedCount)
	}
}

// MARK: Private decode methods

extension Opus.Decoder {
	private func decode(_ input: UnsafeBufferPointer<UInt8>, to output: UnsafeMutableBufferPointer<Int16>) throws -> Int {
		let decodedCount = opus_decode(
			decoder,
			input.baseAddress!,
			Int32(input.count),
			output.baseAddress!,
			Int32(output.count),
			0
		)
		if decodedCount < 0 {
			throw Opus.Error(decodedCount)
		}
		return Int(decodedCount)
	}

	private func decode(_ input: UnsafeBufferPointer<UInt8>, to output: UnsafeMutableBufferPointer<Float32>) throws -> Int {
		let decodedCount = opus_decode_float(
			decoder,
			input.baseAddress!,
			Int32(input.count),
			output.baseAddress!,
			Int32(output.count),
			0
		)
		if decodedCount < 0 {
			throw Opus.Error(decodedCount)
		}
		return Int(decodedCount)
	}
}

// MARK: CMSampleBuffer decode methods

extension Opus.Decoder {
	/// 解码 Opus 数据到 CMSampleBuffer
	/// - Parameter input: 输入的 Opus 编码数据
	/// - Returns: 解码后的 CMSampleBuffer
	/// - Throws: Opus.Error 解码过程中的错误
	public func decodeToCMSampleBuffer(_ input: Data) throws -> CMSampleBuffer {
		let audioBuffer = try decode(input)
		return try createCMSampleBuffer(from: audioBuffer)
	}

	/// 解码 Opus 数据到 CMSampleBuffer
	/// - Parameters:
	///   - input: 输入的 Opus 编码数据缓冲区
	///   - presentationTimeStamp: 显示时间戳
	/// - Returns: 解码后的 CMSampleBuffer
	/// - Throws: Opus.Error 解码过程中的错误
	public func decodeToCMSampleBuffer(_ input: Data, presentationTimeStamp: CMTime = CMTime.zero) throws -> CMSampleBuffer {
		let audioBuffer = try decode(input)
		return try createCMSampleBuffer(from: audioBuffer, presentationTimeStamp: presentationTimeStamp)
	}

	/// 从 AVAudioPCMBuffer 创建 CMSampleBuffer
	/// - Parameters:
	///   - audioBuffer: 音频PCM缓冲区
	///   - presentationTimeStamp: 显示时间戳，默认为零
	/// - Returns: CMSampleBuffer
	/// - Throws: Opus.Error 转换过程中的错误
	private func createCMSampleBuffer(from audioBuffer: AVAudioPCMBuffer, presentationTimeStamp: CMTime = CMTime.zero) throws -> CMSampleBuffer {
		let audioBufferList = audioBuffer.audioBufferList.pointee

		// 创建音频格式描述
		var audioFormatDescription: CMAudioFormatDescription?
		let status = CMAudioFormatDescriptionCreate(
			allocator: kCFAllocatorDefault,
			asbd: audioBuffer.format.streamDescription,
			layoutSize: 0,
			layout: nil,
			magicCookieSize: 0,
			magicCookie: nil,
			extensions: nil,
			formatDescriptionOut: &audioFormatDescription
		)

		guard status == noErr, let formatDescription = audioFormatDescription else {
			throw Opus.Error.internalError
		}

		// 创建 CMBlockBuffer 来存储音频数据
		var blockBuffer: CMBlockBuffer?
		let frameCount = Int(audioBuffer.frameLength)
		let bytesPerFrame = audioBuffer.format.streamDescription.pointee.mBytesPerFrame
		let dataSize = frameCount * Int(bytesPerFrame)

		let blockBufferStatus = CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault,
			memoryBlock: nil,
			blockLength: dataSize,
			blockAllocator: kCFAllocatorDefault,
			customBlockSource: nil,
			offsetToData: 0,
			dataLength: dataSize,
			flags: 0,
			blockBufferOut: &blockBuffer
		)

		guard blockBufferStatus == noErr, let buffer = blockBuffer else {
			throw Opus.Error.internalError
		}

		// 将音频数据复制到 CMBlockBuffer
		let copyStatus = CMBlockBufferReplaceDataBytes(
			with: audioBufferList.mBuffers.mData!,
			blockBuffer: buffer,
			offsetIntoDestination: 0,
			dataLength: dataSize
		)

		guard copyStatus == noErr else {
			throw Opus.Error.internalError
		}

		// 创建样本缓冲区
		var sampleBuffer: CMSampleBuffer?
		var sampleTiming = CMSampleTimingInfo(
			duration: CMTime(value: CMTimeValue(frameCount), timescale: Int32(audioBuffer.format.sampleRate)),
			presentationTimeStamp: presentationTimeStamp,
			decodeTimeStamp: CMTime.invalid
		)

		let createStatus = CMSampleBufferCreate(
			allocator: kCFAllocatorDefault,
			dataBuffer: buffer,
			dataReady: true,
			makeDataReadyCallback: nil,
			refcon: nil,
			formatDescription: formatDescription,
			sampleCount: frameCount,
			sampleTimingEntryCount: 1,
			sampleTimingArray: &sampleTiming,
			sampleSizeEntryCount: 0,
			sampleSizeArray: nil,
			sampleBufferOut: &sampleBuffer
		)

		guard createStatus == noErr, let finalBuffer = sampleBuffer else {
			throw Opus.Error.internalError
		}

		return finalBuffer
	}
}
