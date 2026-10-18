import React from "react";
import { Sequence, useVideoConfig } from "remotion";
import { IslandShot } from "../parts/IslandShot";
import { Keycaps, Pinchpad, SizeTag } from "../parts/Inputs";
import { Caption, Cursor } from "../parts/Overlays";

/**
 * One take of the "sizes" recording, from 2.1 s in, with the island already open at medium.
 * The app reacts about 0.3 s after each cue of the demo script, so a cue at T changes the size
 * here at T − 1.8.
 */
export const SizesShot: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <IslandShot
      version="sizes"
      from={2.1}
      durationInFrames={684}
      overlay={
        <>
          <SizeTag
            changes={[
              [0, "Medium"],
              [0.8, "Large"],
              [2.8, "Medium"],
              [4.6, "Small"],
              [6.6, "Medium"],
              [8.2, "Large"],
              [10.0, "Medium"],
            ]}
          />
          <Sequence name="Bigger" durationInFrames={1.9 * fps} premountFor={fps}>
            <Pinchpad pinches={[[0.35, 0.95, 1]]} durationInFrames={1.9 * fps} />
            <Caption durationInFrames={1.9 * fps}>Pinch to make it bigger</Caption>
          </Sequence>
          <Sequence name="Smaller" from={1.9 * fps} durationInFrames={3.7 * fps} premountFor={fps}>
            <Pinchpad
              pinches={[
                [0.45, 1.05, -1],
                [2.25, 2.85, -1],
              ]}
              durationInFrames={3.7 * fps}
            />
            <Caption durationInFrames={3.7 * fps}>…or smaller</Caption>
          </Sequence>
          <Sequence name="Keys up" from={5.7 * fps} durationInFrames={3.6 * fps} premountFor={fps}>
            <Keycaps keys={["⌃", "⌥", "⌘", "="]} presses={[0.85, 2.45]} durationInFrames={3.6 * fps} inCorner />
            <Caption durationInFrames={3.6 * fps}>Or from the keyboard, in any app</Caption>
          </Sequence>
          <Sequence name="Keys down" from={9.3 * fps} durationInFrames={2.1 * fps} premountFor={fps}>
            <Keycaps keys={["⌃", "⌥", "⌘", "−"]} presses={[0.65]} durationInFrames={2.1 * fps} inCorner />
            <Caption durationInFrames={2.1 * fps}>Small, medium or large</Caption>
          </Sequence>
        </>
      }
    >
      {/* A pinch needs the cursor over the open video. */}
      <Cursor
        path={[
          [0, 1040, 250],
          [5.3, 1040, 250],
          [5.8, 1560, 760],
        ]}
        hideAfter={5.9}
      />
    </IslandShot>
  );
};
