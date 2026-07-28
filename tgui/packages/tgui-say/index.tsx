/**
 * @file
 * Точка входа бандла панели ввода сообщений.
 *
 * Бандл грузится один раз при логине в скрытую панель и живёт весь раунд.
 */

import './styles/main.scss';

import { createRoot } from 'react-dom/client';

import { TguiSay } from './TguiSay';

// Сторож в tgui.html через восемь секунд показывает отладочный оверлей всем,
// кто не отметился загрузкой. Панель ввода к этому моменту уже работает, но
// молчит, и игрок видит поверх карты красную простыню.
window.__tguiBundleLoaded__ = true;
window.__tguiAppBooted__ = false;
window.__pushTguiDebugEvent__?.('bundleLoaded', { bundle: 'tgui-say' });

const setupApp = () => {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', setupApp);
    return;
  }
  const container = document.getElementById('react-root');
  if (!container) {
    return;
  }
  createRoot(container).render(<TguiSay />);
  window.__tguiAppBooted__ = true;
  window.__pushTguiDebugEvent__?.('appBooted', { bundle: 'tgui-say' });
};

setupApp();
