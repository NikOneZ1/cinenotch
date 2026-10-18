import React from "react";
import { AbsoluteFill, Easing, interpolate, Sequence, useCurrentFrame, useVideoConfig } from "remotion";
import { IslandShot } from "../parts/IslandShot";
import { Keycaps, Trackpad } from "../parts/Inputs";
import { Mascot } from "../parts/Mascot";
import { Caption, Cursor } from "../parts/Overlays";
import { colors, displayFont } from "../theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const outExpo = Easing.bezier(0.16, 1, 0.3, 1);

/**
 * One take of the "keys" recording, from 0.6 s in: the app reacts about 0.3 s after each cue
 * of the demo script, so a cue at T shows up here at T − 0.3 and its key press at T − 0.35.
 */
export const KeysShot: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <IslandShot
      version="keys"
      from={0.6}
      durationInFrames={744}
      overlay={
        <>
          <Sequence name="Open" from={1.6 * fps} durationInFrames={1.8 * fps} premountFor={fps}>
            <Keycaps keys={["⌃", "⌥", "⌘", "O"]} presses={[0.55]} durationInFrames={1.8 * fps} />
            <Caption durationInFrames={1.8 * fps}>Open it from any app</Caption>
          </Sequence>
          <Sequence name="Scrub" from={3 * fps} durationInFrames={4.4 * fps} premountFor={fps}>
            <Trackpad
              swipes={[
                [0.5, 1.7, 1],
                [3.15, 3.75, -1],
              ]}
              durationInFrames={4.4 * fps}
            />
            <Caption durationInFrames={4.4 * fps}>Two fingers to scrub</Caption>
          </Sequence>
          <Sequence name="Pause" from={7.7 * fps} durationInFrames={2.7 * fps} premountFor={fps}>
            <Keycaps keys={["⌃", "⌥", "⌘", "P"]} presses={[0.55, 1.95]} durationInFrames={2.7 * fps} />
            <Caption durationInFrames={2.7 * fps} icon="pause">
              Pause from anywhere
            </Caption>
          </Sequence>
          <Sequence name="Close" from={10.5 * fps} durationInFrames={1.9 * fps} premountFor={fps}>
            <Keycaps keys={["⌃", "⌥", "⌘", "O"]} presses={[0.55]} durationInFrames={1.9 * fps} />
            <Caption durationInFrames={1.9 * fps}>Tuck it away</Caption>
          </Sequence>
        </>
      }
    >
      {/* Scrolling needs the cursor over the open video. */}
      <Cursor
        path={[
          [3.0, 1500, 880],
          [3.4, 1090, 330],
          [7.2, 1090, 330],
          [7.7, 1560, 920],
        ]}
        hideAfter={7.8}
      />
    </IslandShot>
  );
};

/** Dark opener: what's new, in one line. */
export const KeysIntro: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  return (
    <AbsoluteFill
      style={{ background: colors.ink, alignItems: "center", justifyContent: "center", fontFamily: displayFont, gap: 44 }}
    >
      <Mascot
        width={300}
        openness={
          interpolate(t, [0.15, 0.33], [0, 1], { ...clamp, easing: Easing.spring({ damping: 14 }) }) *
          interpolate(t, [1.05, 1.11, 1.18], [1, 0.08, 1], clamp)
        }
        look={interpolate(t, [0.5, 0.65, 0.85, 0.95], [0, 12, 12, 0], clamp)}
        style={{ scale: interpolate(t, [0, 0.45], [0.85, 1], { ...clamp, easing: outExpo, output: "perceptual-scale" }) }}
      />
      <div style={{ textAlign: "center" }}>
        <div
          style={{
            display: "inline-block",
            padding: "10px 26px",
            borderRadius: 999,
            background: colors.accent,
            color: colors.onAccent,
            fontSize: 36,
            fontWeight: 900,
            opacity: interpolate(t, [0.25, 0.5], [0, 1], clamp),
          }}
        >
          New in CineNotch 0.6
        </div>
        <div
          style={{
            color: "white",
            fontSize: 120,
            fontWeight: 900,
            letterSpacing: -2,
            marginTop: 22,
            opacity: interpolate(t, [0.35, 0.7], [0, 1], clamp),
            translate: interpolate(t, [0.35, 0.8], ["0px 40px", "0px 0px"], { ...clamp, easing: outExpo }),
          }}
        >
          Scrub the notch.
        </div>
      </div>
    </AbsoluteFill>
  );
};
