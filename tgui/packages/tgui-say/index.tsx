/**
 * @file
 * Точка входа бандла окна ввода сообщений.
 *
 * Бандл грузится один раз при логине в скрытое окно скина и живёт весь раунд.
 */

import './styles/main.scss';

import { createRoot } from 'react-dom/client';

import { TguiSay } from './TguiSay';

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
};

setupApp();
