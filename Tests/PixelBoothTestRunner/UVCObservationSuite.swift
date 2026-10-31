import PixelBoothCore
import PixelBoothLibrary

func runUVCObservationSuite() async {
  suite("UVCObservation")

  await test("delayedControlsAreBoundToTheirStreamConfiguration") {
    let store = FrameStore()
    let controls = UVCControlSnapshot(exposureTime100us: 125)

    await store.beginConfiguration(deviceID: "camera-a", generation: 4, frameIntervalNanos: 0)
    let accepted = await store.setUVCControls(
      controls, deviceID: "camera-a", generation: 4)
    check(accepted, "matching delayed read applies to its active stream")

    await store.beginConfiguration(deviceID: "camera-b", generation: 5, frameIntervalNanos: 0)
    let oldDevice = await store.setUVCControls(
      controls, deviceID: "camera-a", generation: 4)
    let oldGeneration = await store.setUVCControls(
      controls, deviceID: "camera-b", generation: 4)
    check(!oldDevice && !oldGeneration, "obsolete device and generation reads are discarded")

    await store.invalidate()
    let afterInvalidation = await store.setUVCControls(
      controls, deviceID: "camera-b", generation: 5)
    check(!afterInvalidation, "a completed read cannot repopulate invalidated controls")
  }
}
