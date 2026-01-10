import './style.css'
import {
    AtprotoDohHandleResolver,
    atprotoLoopbackClientMetadata,
    BrowserOAuthClient
} from '@atproto/oauth-client-browser'
import {showError, showLoggedInPage, showLoginForm} from "./ui.js";
import { Agent } from '@atproto/api'
import clientMetadataUrl from '/oauth-client-metadata.json?url'

// For localhost development
const scopes = ['atproto', 'transition:generic']
const redirectUri = 'http://127.0.0.1:5173/callback'
const devClientId = `http://localhost?redirect_uri=${encodeURIComponent(redirectUri)}&scope=${encodeURIComponent(scopes.join(' '))}`

//Can be any dns over http.
const resolver = new AtprotoDohHandleResolver({dohEndpoint: 'https://cloudflare-dns.com/dns-query'});


const client = await BrowserOAuthClient.load({
    handleResolver: resolver,
    // clientId: `${location.origin}${clientMetadataUrl}`
    clientId: import.meta.env.VITE_OAUTH_DOMAIN ? `https://${import.meta.env.VITE_OAUTH_DOMAIN}${clientMetadataUrl}` : devClientId
})


window.oauthClient = client

try {
    const result = await client.init()
    //If a result is set and there is a session, the user is authenticated or was a successful callback
    if (result) {
        const {session, state} = result
        if (state != null) {
            console.log(
                `${session.sub} was successfully authenticated (state: ${state})`,
            )
        } else {
            console.log(`${session.sub} was restored (last active session)`)
        }
        if (session) {
            //This is what actually makes authenticated atproto requests
            window.atpAgent = new Agent(session)
            //Shows the logged in ui page
            await showLoggedInPage(session)
        }
    } else {
        //Shows the login form
        showLoginForm()
    }
}
catch (error) {
    console.error('OAuth client initialization error:', error)
    showError(error.message)
}
