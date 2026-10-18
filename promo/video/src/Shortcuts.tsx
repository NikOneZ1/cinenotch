import React from "react";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { useVideoConfig } from "remotion";
import { KeysIntro, KeysShot } from "./scenes/KeysScene";
import { OutroScene } from "./scenes/TitleScenes";

/** The 0.6.0 post: scrolling over the video and the ⌃⌥⌘ shortcuts, on the real island. */
export const Shortcuts: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <TransitionSeries>
      <TransitionSeries.Sequence name="Intro" durationInFrames={100} premountFor={fps}>
        <KeysIntro />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 16 })} />
      <TransitionSeries.Sequence name="Shot" durationInFrames={744} premountFor={fps}>
        <KeysShot />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 20 })} />
      <TransitionSeries.Sequence name="Outro" durationInFrames={150} premountFor={fps}>
        <OutroScene line="Free for Mac · cinenotch.cam" />
      </TransitionSeries.Sequence>
    </TransitionSeries>
  );
};
