import { Route, Routes } from 'react-router'

import { AuthProvider } from 'client-src/hooks/useAuth'
//import HomePage from '#/pages/HomePage'
//import LoginPage from '#/pages/LoginPage'
//import OAuthCallbackPage from '#/pages/OAuthCallbackPage'
//import Channel from '#/pages/Channel'
import Profile from 'client-src/pages/Profile'

function App() {
  return (
    <div className="min-h-screen">
      <div className="max-w-4xl mx-auto p-4 w-full">
        <AuthProvider>
          <Routes>
            <Route path="/" element={<div>Home Page</div>} />
            <Route path="/profile/:handle" element={<Profile />} />
            {/*
            <Route path="/" element={<HomePage />} />
            <Route path="/login" element={<LoginPage />} />
            <Route path="/oauth-callback" element={<OAuthCallbackPage />} />
            <Route path="/channel/:channelNsid" element={<Channel />} />
            */}
          </Routes>
        </AuthProvider>
      </div>
    </div>
  )
}

export default App
