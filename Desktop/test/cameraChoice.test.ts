// Choosing the main camera keeps the second one: the second camera chosen as the main one swaps places with it.
import { describe, expect, it } from 'vitest'
import { defaultSettings, secondAfterChoosing, type Settings } from '@shared/settings'

const twoCameras: Settings = {
  ...defaultSettings,
  streamName: 'xiaomi-smart-camera-c200',
  cameraTitle: 'Xiaomi Smart Camera C200',
  secondStreamName: 'xiaomi-smart-camera-c302',
  secondCameraTitle: 'Xiaomi Smart Camera C302',
}

describe('secondAfterChoosing', () => {
  it('swaps the cameras when the second one becomes the main one', () => {
    const patch = { streamName: 'xiaomi-smart-camera-c302', cameraTitle: 'Xiaomi Smart Camera C302' }
    expect(secondAfterChoosing(twoCameras, patch)).toEqual({
      secondStreamName: 'xiaomi-smart-camera-c200',
      secondCameraTitle: 'Xiaomi Smart Camera C200',
    })
  })

  it('leaves the second camera alone when the main one is chosen again or another one is chosen', () => {
    expect(secondAfterChoosing(twoCameras, { streamName: 'xiaomi-smart-camera-c200' })).toEqual({})
    expect(secondAfterChoosing(twoCameras, { streamName: 'kitchen' })).toEqual({})
  })

  it('clears the second camera when there was no main one to swap with', () => {
    const onlySecond = { ...twoCameras, streamName: '', cameraTitle: '' }
    expect(secondAfterChoosing(onlySecond, { streamName: 'xiaomi-smart-camera-c302' })).toEqual({
      secondStreamName: '',
      secondCameraTitle: '',
    })
  })
})
