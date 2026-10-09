import React from "react";
import { Video } from "@remotion/media";
import { AbsoluteFill, interpolate, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { footage, type Version } from "../theme";
import { Notch, Screen } from "./Screen";

/**
 * One shot of the island: the desktop, the recorded island window on top (it has its own
 * transparency and glow), the notch over it, and a slow push-in towards the notch.
 * `from` is where the shot starts in the recording, in seconds; `delay` holds the recording
 * back that long at the start of the shot (the desktop shows on its own meanwhile).
 */
export const IslandShot: React.FC<{
  version: Version;
  from: number;
  delay?: number;
  durationInFrames: number;
  /** Inside the push-in: cursor, camera pulse. */
  children?: React.ReactNode;
  /** Above it, not zoomed: the caption. */
  overlay?: React.ReactNode;
}> = ({ version, from, delay = 0, durationInFrames, children, overlay }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const clip = footage[version];
  return (
    <AbsoluteFill style={{ overflow: "hidden", background: "#000" }}>
      <AbsoluteFill
        style={{
          transformOrigin: "50% 0%",
          scale: interpolate(frame, [0, durationInFrames], [1, 1.045], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      >
        <Screen />
        <Video
          src={staticFile(clip.file)}
          from={Math.round(delay * fps)}
          trimBefore={Math.round(from * fps)}
          muted
          premountFor={fps}
          style={{
            position: "absolute",
            left: (1920 - clip.width) / 2,
            top: 0,
            width: clip.width,
            height: clip.height,
          }}
        />
        <Notch />
        {children}
      </AbsoluteFill>
      {overlay}
    </AbsoluteFill>
  );
};
