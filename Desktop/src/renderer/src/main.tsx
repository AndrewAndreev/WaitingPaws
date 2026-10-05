import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './styles/tokens.css'
import './styles/base.css'
import './styles/shell.css'
import './styles/screens.css'
import { App } from './App'
import { MiniPanel } from './shell/MiniPanel'
import { installBridge } from './platform/bridge'

installBridge()

// `index.html#mini`: the compact always-on-top strip shown while the main window is minimized.
const mini = location.hash === '#mini'

createRoot(document.getElementById('root')!).render(<StrictMode>{mini ? <MiniPanel /> : <App />}</StrictMode>)
