import React from "react";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { AbsoluteFill, useVideoConfig } from "remotion";
import { IslandShot } from "../parts/IslandShot";
import { CameraPulse, Caption, Cursor, VersionTag } from "../parts/Overlays";

/** The redesigned island, the same scene as BeforeScene plus the moments that are new. */
export const AfterScene: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill>
      <TransitionSeries>
        {/* Held back half a second, so the hello plays after the iris has opened. */}
        <TransitionSeries.Sequence name="Starts" durationInFrames={180} premountFor={fps}>
          <IslandShot
            version="new"
            from={0}
            delay={0.5}
            durationInFrames={180}
            overlay={<Caption durationInFrames={180} icon="play">Picture in Picture starts</Caption>}
          />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 10 })} />
        <TransitionSeries.Sequence name="Hover" durationInFrames={216} premountFor={fps}>
          <IslandShot
            version="new"
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
        <TransitionSeries.Sequence name="Peek" durationInFrames={114} premountFor={fps}>
          <IslandShot
            version="new"
            from={6.3}
            durationInFrames={114}
            overlay={<Caption durationInFrames={114} icon="eye">A quick glance</Caption>}
          >
            <CameraPulse at={0.2} />
          </IslandShot>
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 10 })} />
        <TransitionSeries.Sequence name="Glance" durationInFrames={246} premountFor={fps}>
          <IslandShot
            version="new"
            from={8.2}
            durationInFrames={246}
            overlay={<Caption durationInFrames={246} icon="eye">Glance at the camera</Caption>}
          >
            <CameraPulse at={0.3} />
          </IslandShot>
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 10 })} />
        <TransitionSeries.Sequence name="Pause" durationInFrames={135} premountFor={fps}>
          <IslandShot
            version="new"
            from={12.45}
            durationInFrames={135}
            overlay={<Caption durationInFrames={135} icon="pause">Pause</Caption>}
          />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 10 })} />
        <TransitionSeries.Sequence name="Ends" durationInFrames={105} premountFor={fps}>
          <IslandShot
            version="new"
            from={14.95}
            durationInFrames={105}
            overlay={<Caption durationInFrames={105} icon="close">Picture in Picture ends</Caption>}
          />
        </TransitionSeries.Sequence>
      </TransitionSeries>
      <VersionTag label="After" highlighted />
    </AbsoluteFill>
  );
};
