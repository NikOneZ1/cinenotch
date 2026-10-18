import React from "react";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { useVideoConfig } from "remotion";
import { SizesShot } from "./scenes/SizesScene";
import { OutroScene } from "./scenes/TitleScenes";

/** The 0.7.0 post: pinching the island between sizes, then the keys. Starts on the feature. */
export const Sizes: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <TransitionSeries>
      <TransitionSeries.Sequence name="Shot" durationInFrames={684} premountFor={fps}>
        <SizesShot />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 20 })} />
      <TransitionSeries.Sequence name="Outro" durationInFrames={150} premountFor={fps}>
        <OutroScene line="Free for Mac · cinenotch.cam" />
      </TransitionSeries.Sequence>
    </TransitionSeries>
  );
};
