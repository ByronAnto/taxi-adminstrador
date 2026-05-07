import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: {
    extend: {
      colors: {
        primary: {
          DEFAULT: "#1565C0",
          dark: "#0D47A1",
        },
        accent: "#FFC107",
      },
    },
  },
  plugins: [],
};
export default config;
