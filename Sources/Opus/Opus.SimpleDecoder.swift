
import Copus
import Foundation

extension Opus {
	public class SimpleDecoder {
		private let decoder: OpaquePointer
		private let sampleRate: Int32
		private let channelCount: Int32

		public init(sampleRate: Int, channelCount: Int) throws {
			guard channelCount == 1 || channelCount == 2 else {
				throw Opus.Error.badArgument
			}

			self.sampleRate = Int32(sampleRate)
			self.channelCount = Int32(channelCount)

			var error: Opus.Error = .ok
			let decoder = opus_decoder_create(self.sampleRate, self.channelCount, &error.rawValue)
			if error != .ok {
				throw error
			}
			guard let D = decoder else {
				// This should not happen if error is .ok, but as a safeguard.
				throw Opus.Error.internalError
			}
			self.decoder = D
		}

		deinit {
			opus_decoder_destroy(decoder)
		}

		public func reset() throws {
			let error = Opus.Error(opus_decoder_init(decoder, sampleRate, channelCount))
			if error != .ok {
				throw error
			}
		}

		/// Decodes an Opus data packet into 16-bit PCM data.
		///
		/// - Parameters:
		///   - input: The Opus data packet to decode.
		///   - frameSize: The size of the output buffer in samples per channel.
		///   - fec: Flag to indicate if forward error correction data should be decoded.
		/// - Returns: A Data object containing the decoded 16-bit PCM samples.
		public func decode(_ input: Data, frameSize: Int, fec: Bool = false) throws -> Data {
			try input.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
				let inputBuffer = inputPointer.bindMemory(to: UInt8.self)

				// The output buffer is allocated based on the provided frameSize.
				let outputSampleCount = frameSize * Int(channelCount)
				var outputBuffer = [Int16](repeating: 0, count: outputSampleCount)

				let decodedSamples = try outputBuffer.withUnsafeMutableBufferPointer { (outputMutablePointer) -> Int32 in
					let decodedCount = opus_decode(
						decoder,
						inputBuffer.baseAddress,
						Int32(inputBuffer.count),
						outputMutablePointer.baseAddress!,
						Int32(frameSize),
						fec ? 1 : 0
					)

					if decodedCount < 0 {
						throw Opus.Error(decodedCount)
					}
					return decodedCount
				}

				// The actual number of bytes is decoded_samples * channels * sizeof(Int16)
				let byteCount = Int(decodedSamples) * Int(channelCount) * MemoryLayout<Int16>.size
				return Data(bytes: &outputBuffer, count: byteCount)
			}
		}
	}
}
