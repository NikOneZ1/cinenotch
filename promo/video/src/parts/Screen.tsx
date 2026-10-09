import React from "react";
import { AbsoluteFill } from "remotion";
import { NOTCH, SCALE, uiFont } from "../theme";

const MENU_BAR = 32 * SCALE;

/** The desktop behind the island: wallpaper, menu bar and a Safari window with an article. */
export const Screen: React.FC = () => {
  return (
    <AbsoluteFill
      style={{
        background: "linear-gradient(135deg, #F3C9BE 0%, #D8C6EE 55%, #B7CBF2 100%)",
        fontFamily: uiFont,
      }}
    >
      <div
        style={{
          position: "absolute",
          left: 84,
          right: 84,
          top: MENU_BAR + 15,
          bottom: -60,
          background: "white",
          borderRadius: 18,
          overflow: "hidden",
          boxShadow: "0 27px 75px rgba(0,0,0,0.18), 0 0 0 1px rgba(0,0,0,0.12)",
        }}
      >
        <div
          style={{
            height: 57,
            background: "#EDEDF0",
            display: "flex",
            alignItems: "flex-end",
            gap: 3,
            padding: "0 15px 0 126px",
            position: "relative",
          }}
        >
          <div style={{ position: "absolute", left: 21, top: 20, display: "flex", gap: 10 }}>
            {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
              <div key={c} style={{ width: 18, height: 18, borderRadius: 9, background: c }} />
            ))}
          </div>
          <Tab>Golden hour drive · 4K</Tab>
          <Tab active>Shipping your first Mac app</Tab>
          <Tab>Release notes</Tab>
        </div>
        <div
          style={{
            height: 60,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            borderBottom: "1px solid #EAEAEA",
          }}
        >
          <div
            style={{
              width: 630,
              height: 39,
              borderRadius: 12,
              background: "#F0F0F2",
              color: "#666",
              fontSize: 18,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            docs.example.com/building-a-mac-app
          </div>
        </div>
        <div style={{ padding: "70px 0 0 180px", width: 1170 }}>
          <div style={{ fontSize: 51, fontWeight: 700, color: "#151515", letterSpacing: -1, marginBottom: 12 }}>
            Shipping your first Mac app
          </div>
          <div style={{ fontSize: 25, color: "#6A6A6E", marginBottom: 46 }}>
            A practical guide, from the first window to the App Store
          </div>
          {[94, 90, 97, 72].map((w, i) => (
            <Line key={`a${i}`} width={w} />
          ))}
          <div style={{ height: 30 }} />
          {[96, 88, 93, 64, 91].map((w, i) => (
            <Line key={`b${i}`} width={w} />
          ))}
        </div>
      </div>

      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          top: 0,
          height: MENU_BAR,
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "0 27px",
          fontSize: 20,
          color: "#111",
          background: "rgba(255,255,255,0.55)",
          backdropFilter: "blur(24px)",
        }}
      >
        <div style={{ display: "flex", gap: 27 }}>
          <b>Safari</b>
          <span>File</span>
          <span>Edit</span>
          <span>View</span>
          <span>History</span>
        </div>
        <div style={{ display: "flex", gap: 27 }}>
          <span>Fri 9 Oct&nbsp;&nbsp;14:32</span>
        </div>
      </div>
    </AbsoluteFill>
  );
};

const Tab: React.FC<{ children: string; active?: boolean }> = ({ children, active }) => (
  <div
    style={{
      height: 45,
      padding: "0 24px",
      display: "flex",
      alignItems: "center",
      fontSize: 18,
      color: active ? "#111" : "#5A5A5E",
      background: active ? "white" : "transparent",
      borderRadius: "12px 12px 0 0",
      whiteSpace: "nowrap",
    }}
  >
    {children}
  </div>
);

const Line: React.FC<{ width: number }> = ({ width }) => (
  <div style={{ height: 18, width: `${width}%`, borderRadius: 9, background: "#E4E4E8", marginBottom: 22 }} />
);

/** The camera housing, drawn over everything: the island hides under it, as on a real MacBook. */
export const Notch: React.FC = () => (
  <div
    style={{
      position: "absolute",
      left: (1920 - NOTCH.width) / 2,
      top: 0,
      width: NOTCH.width,
      height: NOTCH.height,
      background: "#000",
      borderRadius: "0 0 16px 16px",
    }}
  >
    <div
      style={{
        position: "absolute",
        left: NOTCH.width / 2 - 5,
        top: NOTCH.height / 2 - 5,
        width: 10,
        height: 10,
        borderRadius: 5,
        background: "radial-gradient(circle at 35% 35%, #3B4466, #0B0D14 70%)",
      }}
    />
  </div>
);
