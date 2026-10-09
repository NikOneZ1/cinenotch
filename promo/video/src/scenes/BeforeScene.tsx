import React from "react";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { AbsoluteFill, useVideoConfig } from "remotion";
import { IslandShot } from "../parts/IslandShot";
import { CameraPulse, Caption, Cursor, VersionTag } from "../parts/Overlays";

/** The old island, from the recording of the version before the redesign. */
export const BeforeScene: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill>
      <TransitionSeries>
        <TransitionSeries.Sequence name="Starts" durationInFrames={126} premountFor={fps}>
          <IslandShot
            version="old"
            from={0.2}
            durationInFrames={126}
            overlay={<Caption durationInFrames={126} icon="play">Picture in Picture starts</Caption>}
          />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 10 })} />
        <TransitionSeries.Sequence name="Hover" durationInFrames={216} premountFor={fps}>
          <IslandShot
            version="old"
            from={2.2}
            durationInFrames={216}
            overlay={<Caption durationInFrames={216} icon="cursor">Hover the island</Caption>}
          >
            <Cursor
              path={[
                [0, 1250, 760],
                [0.28, 1010, 22],
                [2.35, 1010, 22],
                [2.85, 1420, 880],
              ]}
              hideAfter={3.3}
            />
          </IslandShot>
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 10 })} />
        <TransitionSeries.Sequence name="Glance" durationInFrames={246} premountFor={fps}>
          <IslandShot
            version="old"
            from={8.2}
            durationInFrames={246}
            overlay={<Caption durationInFrames={246} icon="eye">Glance at the camera</Caption>}
          >
            <CameraPulse at={0.3} />
          </IslandShot>
        </TransitionSeries.Sequence>
      </TransitionSeries>
      <VersionTag label="Before" />
    </AbsoluteFill>
  );
};
