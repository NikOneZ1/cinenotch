import React from "react";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { fade } from "@remotion/transitions/fade";
import { useVideoConfig } from "remotion";
import { AfterScene } from "./scenes/AfterScene";
import { BeforeScene } from "./scenes/BeforeScene";
import { IrisOverlay } from "./scenes/IrisOverlay";
import { IntroScene, OutroScene } from "./scenes/TitleScenes";

/** The whole film: intro, the old island, the iris, the new island, outro. */
export const BeforeAfter: React.FC = () => {
  const { fps } = useVideoConfig();
  return (
    <TransitionSeries>
      <TransitionSeries.Sequence name="Intro" durationInFrames={120} premountFor={fps}>
        <IntroScene />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 20 })} />
      <TransitionSeries.Sequence name="Before" durationInFrames={568} premountFor={fps}>
        <BeforeScene />
      </TransitionSeries.Sequence>
      <TransitionSeries.Overlay durationInFrames={120} premountFor={fps}>
        <IrisOverlay />
      </TransitionSeries.Overlay>
      <TransitionSeries.Sequence name="After" durationInFrames={946} premountFor={fps}>
        <AfterScene />
      </TransitionSeries.Sequence>
      <TransitionSeries.Transition presentation={fade()} timing={linearTiming({ durationInFrames: 24 })} />
      <TransitionSeries.Sequence name="Outro" durationInFrames={168} premountFor={fps}>
        <OutroScene />
      </TransitionSeries.Sequence>
    </TransitionSeries>
  );
};
