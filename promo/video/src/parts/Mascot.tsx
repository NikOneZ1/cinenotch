import React from "react";
import { colors } from "../theme";

/** Two glowing lime eyes with catchlights. `openness` 0 is shut, 1 open. */
export const Eyes: React.FC<{
  size: number;
  openness: number;
  look?: number;
  style?: React.CSSProperties;
}> = ({ size, openness, look = 0, style }) => {
  const eye = { width: size * 0.62, height: size * 0.92 };
  return (
    <div
      style={{
        display: "flex",
        gap: size * 1.0,
        translate: `${look}px 0px`,
        scale: `1 ${Math.max(0.02, openness)}`,
        ...style,
      }}
    >
      {[0, 1].map((i) => (
        <div
          key={i}
          style={{
            position: "relative",
            width: eye.width,
            height: eye.height,
            borderRadius: "50%",
            background: colors.accent,
            boxShadow: `0 0 ${size * 0.45}px ${colors.accent}AA`,
          }}
        >
          <div
            style={{
              position: "absolute",
              left: eye.width * 0.2,
              top: eye.height * 0.14,
              width: eye.width * 0.3,
              height: eye.width * 0.3,
              borderRadius: "50%",
              background: "rgba(255,255,255,0.9)",
            }}
          />
        </div>
      ))}
    </div>
  );
};

/** The mascot: a black island with eyes. */
export const Mascot: React.FC<{
  width: number;
  openness: number;
  look?: number;
  style?: React.CSSProperties;
}> = ({ width, openness, look = 0, style }) => (
  <div
    style={{
      width,
      height: width * 0.46,
      borderRadius: width,
      background: "linear-gradient(180deg, #2A2A28 0%, #0B0B0A 45%, #050505 100%)",
      boxShadow: "0 30px 60px rgba(58,46,20,0.28), inset 0 1px 0 rgba(255,255,255,0.08)",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      ...style,
    }}
  >
    <Eyes size={width * 0.1} openness={openness} look={look} />
  </div>
);
