import type { Theme } from 'vitepress';
import DefaultTheme from 'vitepress/theme';
import './custom.css';

const STANDALONE_APP_RE = /^\/(?:opencad\/)?(?:studio(?:\/|$)|feascript-demo(?:\.html|\/|$)|demos\/feascript(?:\/|$)|opencad-portable\.html)/;

export default {
  extends: DefaultTheme,
  enhanceApp({ router }) {
    if (typeof window !== 'undefined') {
      router.onBeforeRouteChange = (to: string) => {
        try {
          const url = new URL(to, window.location.origin);
          if (STANDALONE_APP_RE.test(url.pathname)) {
            window.location.assign(url.href);
            return false;
          }
        } catch {}
        return true;
      };
    }
  },
} satisfies Theme;
