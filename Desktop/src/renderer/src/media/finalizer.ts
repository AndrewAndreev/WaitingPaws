// Port of the Mac app's `RecordingFinalizer` without AVFoundation (and without ffmpeg): mediabunny reads and writes
// the MP4, the browser's WebCodecs decode the camera's sound (Opus, FLAC, PCMA/PCMU…) and encode AAC. It runs in a
// hidden window of the desktop app; in a web build the same code can run in the page or a worker.
//
// One pass does both jobs of the Mac version:
//   * finalize — go2rtc's fragmented MP4 becomes a regular MP4: the video is copied packet by packet (no
//     re-encoding), the sound is converted to AAC, and a silent AAC track is added when the camera gave no sound
//     (Telegram sends a video without sound as a GIF, most players and galleries only accept AAC in MP4);
//   * join — the parts of a recording the camera broke off are put back into one file, each at its own time since
//     the recording started: the time the camera was away stays an empty stretch (the last frame and silence), so
//     the training log ("jump to the exit") still lines up with the picture.
// Pauses inside the sound (packets the camera dropped, a reconnect — go2rtc keeps them as a longer packet before
// the pause) come back as silence: decoders run the sound on, which would put it ahead of the picture.
import {
  ALL_FORMATS,
  AudioSample,
  AudioSampleSink,
  AudioSampleSource,
  CustomSource,
  EncodedPacket,
  EncodedPacketSink,
  EncodedVideoPacketSource,
  Input,
  Mp4OutputFormat,
  Output,
  StreamTarget,
  type InputAudioTrack,
  type InputVideoTrack,
  type StreamTargetChunk,
} from 'mediabunny'

export interface MediaIO {
  size(path: string): Promise<number>
  read(path: string, start: number, end: number): Promise<Uint8Array>
  create(path: string): Promise<number>
  write(handle: number, position: number, data: Uint8Array): Promise<void>
  close(handle: number): Promise<void>
  log(line: string): void
}

export interface RecordingPart {
  path: string
  /// Seconds from the start of the whole recording at which this part begins.
  offset: number
}

/// AAC as WebCodecs encodes it on Windows and in browsers: 44.1 or 48 kHz only.
const OUTPUT_RATE = 48_000
/// A pause shorter than this is just jitter in the packet times.
const MIN_PAUSE = 0.005

function source(io: MediaIO, path: string): CustomSource {
  return new CustomSource({
    getSize: () => io.size(path),
    read: (start, end) => io.read(path, start, end),
    prefetchProfile: 'fileSystem',
    maxCacheSize: 16 * 1024 * 1024,
  })
}

/// Writes `parts` into `outputPath` as one regular MP4 with AAC sound. Throws when nothing could be read.
export async function writeRecording(io: MediaIO, parts: RecordingPart[], outputPath: string): Promise<{ duration: number; parts: number }> {
  const inputs: { input: Input; video: InputVideoTrack; audio: InputAudioTrack | null; offset: number; path: string }[] = []
  try {
    for (const part of parts) {
      const input = new Input({ source: source(io, part.path), formats: ALL_FORMATS })
      try {
        const video = await input.getPrimaryVideoTrack()
        if (!video) {
          io.log(`[rec] ${part.path}: no video, skipped`)
          input.dispose()
          continue
        }
        const audio = (await input.getAudioTracks())[0] ?? null
        inputs.push({ input, video, audio, offset: part.offset, path: part.path })
      } catch (error) {
        io.log(`[rec] ${part.path}: unreadable (${(error as Error).message}), skipped`)
        input.dispose()
      }
    }
    if (!inputs.length) throw new Error('в файле нет видео')

    const handle = await io.create(outputPath)
    const writable = new WritableStream<StreamTargetChunk>({
      write: (chunk) => io.write(handle, chunk.position, chunk.data),
    })
    const output = new Output({ format: new Mp4OutputFormat({ fastStart: false }), target: new StreamTarget(writable, { chunked: true, chunkSize: 4 * 1024 * 1024 }) })
    try {
      const first = inputs[0]
      const codec = first.video.codec
      if (!codec) throw new Error('неизвестный видеокодек')
      const videoSource = new EncodedVideoPacketSource(codec)
      output.addVideoTrack(videoSource, { rotation: first.video.rotation })
      const channels = Math.min(2, Math.max(1, ...inputs.map((item) => item.audio?.numberOfChannels ?? 1)))
      const audioSource = new AudioSampleSource({ codec: 'aac', bitrate: await aacBitrate(channels) })
      output.addAudioTrack(audioSource)
      await output.start()

      const audio = new AudioPlacer(audioSource, channels)
      let end = 0
      let previousVideoEnd = 0
      for (const [index, item] of inputs.entries()) {
        // Video: packets copied as they are, moved to the part's place on the recording's timeline.
        const sink = new EncodedPacketSink(item.video)
        const firstPacket = await sink.getFirstPacket()
        if (!firstPacket) continue
        const origin = firstPacket.timestamp
        const config = await item.video.getDecoderConfig()
        // A part never starts before the previous one ended (the clocks of two requests can overlap a little).
        const shift = Math.max(item.offset, previousVideoEnd) - origin
        let firstOfPart = true
        let lastEnd = previousVideoEnd
        for await (const packet of sink.packets()) {
          const timestamp = packet.timestamp + shift
          const moved = new EncodedPacket(packet.data, packet.type, timestamp, packet.duration)
          await videoSource.add(moved, firstOfPart && config ? { decoderConfig: config } : undefined)
          firstOfPart = false
          lastEnd = Math.max(lastEnd, timestamp + packet.duration)
        }
        previousVideoEnd = lastEnd
        end = Math.max(end, lastEnd)

        // Sound: decoded, put at the same place (silence before it and in its pauses), encoded as AAC.
        if (item.audio && (await item.audio.canDecode())) {
          const audioSink = new AudioSampleSink(item.audio)
          for await (const sample of audioSink.samples()) {
            await audio.place(sample, sample.timestamp + shift)
            sample.close()
          }
        } else if (item.audio) {
          io.log(`[rec] part ${index + 1}: sound ${item.audio.codec} can't be decoded here, silence instead`)
        }
      }
      // Silence up to the end of the video: a track without sound, or sound that ended early.
      await audio.silenceUntil(end)
      audioSource.close()
      videoSource.close()
      await output.finalize()
      return { duration: end, parts: inputs.length }
    } catch (error) {
      await output.cancel().catch(() => undefined)
      throw error
    } finally {
      await io.close(handle)
    }
  } finally {
    for (const item of inputs) item.input.dispose()
  }
}

/// A bitrate the platform's AAC encoder takes: Windows (Media Foundation) only accepts 96, 128, 160 and 192 kbit/s,
/// other encoders take any; the lowest that works is plenty for a camera's microphone.
async function aacBitrate(channels: number): Promise<number> {
  const candidates = channels === 2 ? [128_000, 96_000, 160_000, 192_000] : [96_000, 64_000, 128_000]
  for (const bitrate of candidates) {
    try {
      const support = await AudioEncoder.isConfigSupported({ codec: 'mp4a.40.2', sampleRate: OUTPUT_RATE, numberOfChannels: channels, bitrate })
      if (support.supported) return bitrate
    } catch {
      // Try the next one.
    }
  }
  return candidates[0]
}

/// Resamples the decoded sound to 48 kHz, places it on the output timeline and fills every gap with silence.
class AudioPlacer {
  /// Output time (s) up to which sound has been written.
  private written = 0

  constructor(
    private readonly target: AudioSampleSource,
    private readonly channels: number,
  ) {}

  /// The sound is written end to end: a gap longer than MIN_PAUSE before `at` becomes silence, a smaller one or an
  /// overlap (rounding, two parts' clocks) is absorbed by cutting the overlapping start.
  async place(sample: AudioSample, at: number): Promise<void> {
    if (at + sample.duration <= this.written) return // entirely inside what is already written
    if (at - this.written > MIN_PAUSE) await this.silenceUntil(at)
    const planes = resample(sample, this.channels, OUTPUT_RATE)
    const skip = at < this.written ? Math.round((this.written - at) * OUTPUT_RATE) : 0
    const frames = planes[0].length - skip
    if (frames <= 0) return
    const data = new Float32Array(frames * this.channels)
    for (let channel = 0; channel < this.channels; channel++) data.set(planes[channel].subarray(skip, skip + frames), channel * frames)
    await this.add(data, frames)
  }

  private async add(data: Float32Array, frames: number): Promise<void> {
    const sample = new AudioSample({ data, format: 'f32-planar', numberOfChannels: this.channels, sampleRate: OUTPUT_RATE, timestamp: this.written })
    try {
      await this.target.add(sample)
    } finally {
      sample.close()
    }
    this.written += frames / OUTPUT_RATE
  }

  /// Silence from what is written so far up to `time`, in pieces of up to 1 s.
  async silenceUntil(time: number): Promise<void> {
    while (time - this.written > 1 / OUTPUT_RATE) {
      const frames = Math.min(OUTPUT_RATE, Math.round((time - this.written) * OUTPUT_RATE))
      if (frames <= 0) break
      await this.add(new Float32Array(frames * this.channels), frames)
    }
  }
}

/// The sample's sound as `channels` planes at `rate` (linear interpolation: camera sound is 8–48 kHz speech and
/// room noise, nothing a better filter would make audible).
function resample(sample: AudioSample, channels: number, rate: number): Float32Array[] {
  const inFrames = sample.numberOfFrames
  const source: Float32Array[] = []
  for (let channel = 0; channel < sample.numberOfChannels; channel++) {
    const plane = new Float32Array(inFrames)
    sample.copyTo(plane, { planeIndex: channel, format: 'f32-planar' })
    source.push(plane)
  }
  const pick = (channel: number) => source[Math.min(channel, source.length - 1)]
  if (sample.sampleRate === rate) return Array.from({ length: channels }, (_, channel) => pick(channel))
  const outFrames = Math.max(1, Math.round((inFrames * rate) / sample.sampleRate))
  const ratio = sample.sampleRate / rate
  return Array.from({ length: channels }, (_, channel) => {
    const input = pick(channel)
    const output = new Float32Array(outFrames)
    for (let i = 0; i < outFrames; i++) {
      const position = i * ratio
      const index = Math.floor(position)
      const fraction = position - index
      const a = input[Math.min(index, inFrames - 1)]
      const b = input[Math.min(index + 1, inFrames - 1)]
      output[i] = a + (b - a) * fraction
    }
    return output
  })
}

/// Whether a file still needs finalizing: fragmented MP4 (go2rtc's), or sound that isn't AAC.
export async function needsFinalizing(io: MediaIO, path: string): Promise<boolean> {
  if (await isFragmented(io, path)) return true
  const input = new Input({ source: source(io, path), formats: ALL_FORMATS })
  try {
    const audio = (await input.getAudioTracks())[0]
    return !audio || audio.codec !== 'aac'
  } finally {
    input.dispose()
  }
}

/// Walks the top-level MP4 boxes looking for `moof` (or `mvex` inside `moov`).
async function isFragmented(io: MediaIO, path: string): Promise<boolean> {
  const size = await io.size(path)
  let offset = 0
  while (offset + 8 <= size) {
    const header = await io.read(path, offset, Math.min(size, offset + 16))
    const view = new DataView(header.buffer, header.byteOffset, header.byteLength)
    let boxSize = view.getUint32(0)
    const type = String.fromCharCode(header[4], header[5], header[6], header[7])
    if (type === 'moof' || type === 'mfra') return true
    if (boxSize === 1 && header.byteLength >= 16) boxSize = Number(view.getBigUint64(8))
    if (boxSize === 0) break
    if (boxSize < 8) break
    offset += boxSize
  }
  return false
}
