import { Composition, Folder } from "remotion";
import { BeforeAfter } from "./BeforeAfter";
import { AfterScene } from "./scenes/AfterScene";
import { BeforeScene } from "./scenes/BeforeScene";
import { IrisOverlay } from "./scenes/IrisOverlay";
import { IntroScene, OutroScene } from "./scenes/TitleScenes";

const video = { width: 1920, height: 1080, fps: 60 } as const;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition id="BeforeAfter" component={BeforeAfter} durationInFrames={1758} {...video} />
      <Folder name="Scenes">
        <Composition id="Intro" component={IntroScene} durationInFrames={120} {...video} />
        <Composition id="Before" component={BeforeScene} durationInFrames={568} {...video} />
        <Composition id="Iris" component={IrisOverlay} durationInFrames={120} {...video} />
        <Composition id="After" component={AfterScene} durationInFrames={946} {...video} />
        <Composition id="Outro" component={OutroScene} durationInFrames={168} {...video} />
      </Folder>
    </>
  );
};
