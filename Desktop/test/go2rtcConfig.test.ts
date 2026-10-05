// Port of Go2RTCConfigTests.swift.
import { describe, expect, it } from 'vitest'
import { Go2RTCClient } from '@core/index'

const config = `# Waiting Paws embedded go2rtc
api:
  listen: "127.0.0.1:11984"
streams:
  testcam:
    - rtsp://127.0.0.1:8554/testcam
  kitchen: xiaomi://123456:cn@192.168.1.20?did=987&model=chuangmi.camera.v6&subtype=3
  quoted:
  - "ffmpeg:virtual?video#video=h264"
  flow: [rtsp://a/1, 'rtsp://b/2']
xiaomi:
  "123456": token`

describe('Go2RTC config', () => {
  it('reads a block list', () => {
    expect(Go2RTCClient.streamSources(config, 'testcam')).toEqual(['rtsp://127.0.0.1:8554/testcam'])
  })

  it('keeps the query of an inline xiaomi source', () => {
    expect(Go2RTCClient.streamSources(config, 'kitchen')).toEqual([
      'xiaomi://123456:cn@192.168.1.20?did=987&model=chuangmi.camera.v6&subtype=3',
    ])
  })

  it('keeps the hash of a quoted item', () => {
    expect(Go2RTCClient.streamSources(config, 'quoted')).toEqual(['ffmpeg:virtual?video#video=h264'])
  })

  it('reads a flow list', () => {
    expect(Go2RTCClient.streamSources(config, 'flow')).toEqual(['rtsp://a/1', 'rtsp://b/2'])
  })

  it('reads only the streams section', () => {
    expect(Go2RTCClient.streamSources(config, 'listen')).toEqual([])
    expect(Go2RTCClient.streamSources(config, '123456')).toEqual([])
    expect(Go2RTCClient.streamSources(config, 'missing')).toEqual([])
  })

  it('handles CRLF line ends', () => {
    expect(Go2RTCClient.streamSources(config.replace(/\n/g, '\r\n'), 'testcam')).toEqual([
      'rtsp://127.0.0.1:8554/testcam',
    ])
  })
})
