/** @type {import('tailwindcss').Config} */
export default {
  content: [
    './index.html',
    './src/**/*.{js,ts,jsx,tsx}',
  ],
  theme: {
    extend: {
      colors: {
        valen: {
          bg: '#0c1626',
          surface: 'rgba(255,255,255,0.06)',
          'surface-strong': 'rgba(255,255,255,0.10)',
          'surface-muted': '#162032',
          ink: '#f0f4fa',
          'ink-2': '#c8d8ef',
          muted: '#8fa3be',
          subtle: '#5c7492',
          accent: '#7c5cfc',
          'accent-hover': '#9474fd',
          'accent-dim': 'rgba(124,92,252,0.18)',
          success: '#4dd68c',
          danger: '#f06b78',
          warning: '#f5a623',
        },
      },
      fontFamily: {
        display: ['Space Grotesk', 'sans-serif'],
        body: ['DM Sans', 'sans-serif'],
        mono: ['JetBrains Mono', 'Menlo', 'monospace'],
      },
      backgroundImage: {
        'valen-gradient': 'linear-gradient(180deg, #0c1626 0%, #0d1b2f 58%, #111f38 100%)',
      },
    },
  },
  plugins: [],
}

