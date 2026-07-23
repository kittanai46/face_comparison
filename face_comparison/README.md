# Face comparison / liveness check

Flutter prototype for on-device face-presence and active liveness checking.
The scan has two stages:

1. A medium-distance guide asks the user to keep their face between 20% and
   42% of the camera image width (the near stage starts at 50%). One
   high-confidence face of the expected size must remain stable for several
   frames. An EfficientDet-Lite COCO detector also rejects repeated detections
   of presentation media (`cell phone`, `tv`, `laptop`, or `book`) before the
   near stage unlocks.
2. The guide grows and asks the user to approach until the face occupies at
   least 50% of the camera width. The app measures baseline
   RGB values, generates a four-pulse one-time RGBW code with randomized
   order at full intensity, and verifies that the
   colour proportions observed by the camera follow that exact code. A single
   unpredictable white pulse secretly checks for a blink or squint that
   starts only after the pulse before requiring head turns. White
   reflection magnitude is diagnostic only because bright ambient light can
   leave no additional camera headroom; the eye response is the decisive white
   challenge signal. Eye response combines blendshape eye-open probability with
   MediaPipe mesh Eye Aspect Ratio. Both a complete blink and a sustained squint
   with a sufficient neutral-relative drop are accepted, so a missed reopening
   frame does not cause a false rejection.

During the colour challenge the app immediately sets application brightness to
100% and renders a 94%-opaque illumination layer from preparation through the
end of RGBW sampling. A short dark-neutral reference is recorded once before
the continuous burst; the eye check is
bound to one randomly selected white pulse, so a prerecorded video cannot know
when the app will inspect the eye-open sequence. The detector must first see an
open-eye frame after that pulse begins, then a neutral-relative close/squint;
a blink already underway before the challenge is not accepted. The instruction UI remains
clearly visible. The app
chooses a camera exposure offset from measured face luminance and collects one
shared 200 ms neutral reference immediately before the burst. The four colours
then run continuously with no dark gaps: red, green and blue last 400 ms each,
while the white blink-observation pulse lasts 800 ms, for exactly 2,000 ms of
illumination. Every RGBW pulse uses 100% intensity; only the colour order is
randomized. Sampling is based on elapsed time with a
minimum sample count instead of a fixed frame count. The detector also records
the first intended-channel change as the real response onset. This produces a
short one-time sequence while limiting colour carry-over and avoiding
mistaking slow model FPS for response latency. The user's brightness is
restored as soon as the scan page closes. The full scan timeout is 75 seconds.
Chromatic response thresholds are reduced modestly when that colour's neutral
baseline is already bright, while still requiring at least two of three RGB
channels plus the randomized white-pulse blink.

The near guide uses a larger face-shaped outline and accepts the detected face
from 50% of the image width. Before RGB sampling, outer-background
brightness is compared with the central face region. A backlight warning now
requires a severely underexposed face below 80 luma, a bright background over
210 luma, a ratio over 2.20, and six consecutive frames. A white or brightly
coloured wall is therefore accepted while the face remains readable. Three
recovered frames are required before sampling resumes, preventing one-frame
auto-exposure changes from resetting a valid baseline.
It also pauses baseline and colour sampling when the face ROI is overexposed or
too many sampled pixels are saturated, because clipped RGB channels cannot
provide trustworthy colour-reflection evidence.

RGB sampling uses an invisible dynamic rectangular ROI derived from the actual
face bounding box and mapped back through camera rotation. In addition to the
whole inner face, forehead, both cheeks and the central nose area are sampled
separately. Each region must correlate over time with the same randomized
pulse code, making a single global brightness change insufficient. Background
light is sampled outside a 1.5x expanded face ROI.
Face discovery still runs on the full frame so an off-centre user can recover.

Each RGBW pulse is bound to a cryptographically shuffled per-scan order and a
short response window. If the face leaves the accepted distance or the camera
cannot collect enough samples before the two-second deadline, that attempt is
stopped instead of silently extending or restarting the burst. The object detector continues running throughout the
scan (not only at entry), so a phone, TV, laptop or book introduced later is
rejected. Face-ROI sampling also counts repeated high-frequency chroma jumps;
several consecutive frames with screen-like pixel or moire texture are rejected.
Near-stage object detections additionally need high confidence, sustained
detection, and a media box that encloses and extends beyond the face. This
prevents a close real face from being rejected by a one-frame `cell phone`
misclassification.
After illumination, opposite head turns must produce coherent,
opposite nose-to-cheek landmark displacement and enough temporal parallax;
moving a flat image around the frame is therefore not accepted as head motion.
The scanner also records a compact brightness-normalized 63-bit face hash over
the session. Very low visual diversity and repeated eight-frame loops are used
as replay evidence. At completion a combined anti-spoof score fuses temporal
multi-region correlation, frame diversity, screen texture, eye response and
3-D parallax; the classification cannot pass when this score or any mandatory
active check fails.

Brightness limits are calibrated in a dedicated 10-frame pre-calibration phase
before normal overexposure filtering begins and are tagged with the active
front-camera profile. Hard upper safety caps remain in place, while the session
thresholds adapt to differences between front-camera sensors and ambient
exposure. The accepted 50%-90% face-width range is enforced throughout RGB and
head-turn collection, not only when entering the near stage.

Head-turn parallax is measured against a multi-frame neutral pose. Each side is
held for several frames and reduced with a median before the two neutral-relative
deltas are compared. Single noisy landmark frames and natural facial asymmetry
therefore no longer decide the result. Frame-processing exceptions are logged
and a sustained error is returned explicitly instead of silently timing out.

The detector is `face_detection_tflite` (MediaPipe models running on-device).
It supplies the bounding box, 468-point mesh, head pose and eye blendshapes.
`object_detection` supplies the on-device EfficientDet-Lite object gate.
The screen-light measurement is calculated directly from `camera` image
frames, so no network service or additional liveness SDK is required.

While a scan is running, the app also filters eligible non-colour frames for
open eyes, frontal pose, exposure and sufficient face size, then ranks them
primarily with Laplacian focus energy plus a smaller gradient measure. Pose,
eye, exposure, size and mesh quality are only tie-breakers between similarly
sharp frames. Automatic camera focus/exposure remain enabled while candidates
are collected. Only the highest-scoring frame is retained in memory. At
completion the entire camera frame is rotated and mirrored to match the
front-camera preview, scaled down to at most 800 pixels on its long edge while
preserving the camera's native aspect ratio, and encoded as PNG for the
on-device summary card. Camera row stride
and YUV layout are normalized first for NV12, NV21 and I420 devices, with a
luma-only fallback rather than returning a black image when chroma is
unavailable. The capture is not
written to the gallery or another persistent file by this prototype.

This is a prototype, not certified biometric presentation-attack detection.
Thresholds (light-response constants, face-size ranges, pose angles) must be
calibrated on the actual supported phone models and lighting conditions before
production use. High-assurance identity verification should use a certified
PAD SDK or hardware depth/IR sensor.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
