/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: {
          primary: "#1a1b26",
          secondary: "#24283b",
          tertiary: "#414868",
        },
        border: "#3b4261",
        text: {
          primary: "#c0caf5",
          secondary: "#a9b1d6",
          muted: "#565f89",
        },
        accent: {
          blue: "#7aa2f7",
          green: "#9ece6a",
          red: "#f7768e",
          yellow: "#e0af68",
          cyan: "#7dcfff",
          purple: "#bb9af7",
        },
      },
    },
  },
  plugins: [],
};
