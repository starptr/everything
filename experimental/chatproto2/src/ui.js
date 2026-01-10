const appElement = document.getElementById('app')

/**
 * Shows the login form and sets a event listener for form submission to start the OAuth flow.
 */
function showLoginForm() {
    appElement.innerHTML = `
        <div class="container">
            <h1>ATProto OAuth Playground</h1>
            <form id="login-form">
                <div class="form-group">
                    <label for="handle">ATProto Handle</label>
                    <input
                        type="text"
                        id="handle"
                        name="handle"
                        placeholder="jcsalterego.bsky.social"
                        required
                    />
                    <div id="error" class="error"></div>
                </div>
                <button type="submit">Sign In</button>
            </form>
        </div>
    `

    document.querySelector('#login-form').addEventListener('submit', async (e) => {
        e.preventDefault()

        const handle = document.querySelector('#handle').value.trim()
        const errorEl = document.querySelector('#error')
        errorEl.textContent = ''

        try {
            // This will redirect to the OAuth authorization page on the PDS
            await window.oauthClient.signIn(handle)
        } catch (error) {
            console.error('Sign in error:', error)
            errorEl.textContent = error.message || 'Failed to sign in. Please check your handle and try again.'
        }
    })
}

/**
 * Demo component to show an authenticated request by fetching the user's notifications.
 * @returns {Promise<string>}
 */
async function notificationsList(){

    const notifications = await window.atpAgent.app.bsky.notification.listNotifications({
        limit: 5
    })

    return notifications.data.notifications.map(notif => {
        const reasonText = {
            'like': 'liked your post',
            'repost': 'reposted your post',
            'follow': 'followed you',
            'mention': 'mentioned you',
            'reply': 'replied to your post',
            'quote': 'quoted your post'
        }[notif.reason] || notif.reason

        return `
            <div class="notification-item ${!notif.isRead ? 'unread' : ''}">
                <img src="${notif.author.avatar || '/vite.svg'}" alt="${notif.author.displayName}" class="notification-avatar" />
                <div class="notification-content">
                    <p class="notification-text">
                        <strong>${notif.author.displayName || notif.author.handle}</strong> ${reasonText}
                    </p>
                    <p class="notification-time">${new Date(notif.indexedAt).toLocaleString()}</p>
                </div>
            </div>
        `
    }).join('')

}

/**
 * Shows the logged in page with the user's profile and notifications.
 */
async function showLoggedInPage(session) {
    const profile = await window.atpAgent.getProfile({
        actor: session.sub
    })

    const { avatar, displayName, handle, followersCount, followsCount } = profile.data


    appElement.innerHTML = `
        <div class="container">
            <h1>Logged In</h1>
            <div class="profile-card">
                <img src="${avatar || '/vite.svg'}" alt="Profile picture" class="profile-avatar" />
                <div class="profile-info">
                    <h2 class="profile-name">${displayName || handle}</h2>
                    <p class="profile-handle">@${handle}</p>
                    <div class="profile-stats">
                        <span><strong>${followersCount || 0}</strong> Followers</span>
                        <span><strong>${followsCount || 0}</strong> Following</span>
                    </div>
                </div>
            </div>
            <div class="notifications-section">
                <h3>Recent Notifications</h3>
                <div class="notifications-list">
                    ${await notificationsList()}
                </div>
            </div>
            <button id="logout">Sign Out</button>
        </div>
    `

    document.querySelector('#logout').addEventListener('click', async () => {
        try {
            await window.oauthClient.revoke(session.sub)
            showLoginForm()
        } catch (error) {
            console.error('Sign out error:', error)
        }
    })
}

/**
 *
 * DANGER WILL ROBINSON
 */
function showError(message) {
    appElement.innerHTML = `
            <div class="container">
                <h1>ATProto OAuth Playground</h1>
                <div class="error">${message}</div>
                <a href="/">Back to login</a>
            </div>
        `
}


export { showLoginForm, showLoggedInPage, showError }