import type { LinearTicket, LinearConfig } from "../types";

// Linear settings come from the environment only — papyrus writes nothing to
// disk. Set LINEAR_API_KEY (and optionally LINEAR_DEFAULT_TEAM_ID) to enable the
// read-only Linear ticket lookups; absent that, the Linear routes report
// "not configured".
export function loadConfig(): LinearConfig {
  return {
    apiKey: process.env.LINEAR_API_KEY,
    defaultTeamId: process.env.LINEAR_DEFAULT_TEAM_ID,
  };
}

// Linear GraphQL API
const LINEAR_API = "https://api.linear.app/graphql";

async function linearQuery(apiKey: string, query: string, variables?: any) {
  const res = await fetch(LINEAR_API, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: apiKey, // Linear expects just the key, not "Bearer key"
    },
    body: JSON.stringify({ query, variables }),
  });

  if (!res.ok) {
    const text = await res.text();
    console.error(`Linear API error ${res.status}:`, text);
    throw new Error(`Linear API error: ${res.status}`);
  }

  const data = await res.json();
  if (data.errors) {
    console.error("Linear GraphQL errors:", data.errors);
    throw new Error(data.errors[0]?.message || "Linear API error");
  }

  return data.data;
}

// Fetch teams
export async function fetchTeams(apiKey: string) {
  const query = `
    query {
      teams {
        nodes {
          id
          name
          key
        }
      }
    }
  `;
  const data = await linearQuery(apiKey, query);
  return data.teams.nodes;
}

// Fetch active tickets (not completed/canceled)
export async function fetchMyTickets(apiKey: string, teamId?: string): Promise<LinearTicket[]> {
  // Build filter dynamically to avoid GraphQL syntax errors
  // Don't filter by assignee - show all active tickets
  const filterParts = [
    'state: { type: { nin: ["completed", "canceled"] } }',
  ];
  if (teamId) {
    filterParts.push(`team: { id: { eq: "${teamId}" } }`);
  }

  const query = `
    query {
      issues(
        filter: { ${filterParts.join(", ")} }
        first: 50
        orderBy: updatedAt
      ) {
        nodes {
          id
          identifier
          title
          url
          priority
          state {
            name
            color
          }
          assignee {
            name
          }
          team {
            name
            key
          }
        }
      }
    }
  `;

  console.log(`\x1b[38;5;141m[linear]\x1b[0m Fetching tickets with filter:`, filterParts.join(", "));

  const data = await linearQuery(apiKey, query);

  console.log(`\x1b[38;5;141m[linear]\x1b[0m Tickets found:`, data.issues?.nodes?.length || 0);

  return data.issues.nodes;
}

// Search tickets
export async function searchTickets(apiKey: string, searchTerm: string, teamId?: string): Promise<LinearTicket[]> {
  const filterParts = ['state: { type: { nin: ["completed", "canceled"] } }'];
  if (teamId) {
    filterParts.push(`team: { id: { eq: "${teamId}" } }`);
  }

  const query = `
    query($searchTerm: String!) {
      issueSearch(
        query: $searchTerm
        filter: { ${filterParts.join(", ")} }
        first: 20
      ) {
        nodes {
          id
          identifier
          title
          url
          priority
          state {
            name
            color
          }
          assignee {
            name
          }
          team {
            name
            key
          }
        }
      }
    }
  `;
  const data = await linearQuery(apiKey, query, { searchTerm });
  return data.issueSearch.nodes;
}

// Fetch single ticket by identifier (e.g., "PROJ-123")
export async function fetchTicketByIdentifier(apiKey: string, identifier: string): Promise<LinearTicket | null> {
  const query = `
    query($identifier: String!) {
      issue(id: $identifier) {
        id
        identifier
        title
        url
        priority
        state {
          name
          color
        }
        assignee {
          name
        }
        team {
          name
          key
        }
      }
    }
  `;

  try {
    // Try searching by identifier
    const searchQuery = `
      query($term: String!) {
        issueSearch(query: $term, first: 1) {
          nodes {
            id
            identifier
            title
            url
            priority
            state {
              name
              color
            }
            assignee {
              name
            }
            team {
              name
              key
            }
          }
        }
      }
    `;
    const data = await linearQuery(apiKey, searchQuery, { term: identifier });
    return data.issueSearch.nodes[0] || null;
  } catch (e) {
    return null;
  }
}

// Validate API key
export async function validateApiKey(apiKey: string): Promise<boolean> {
  try {
    const query = `query { viewer { id name } }`;
    await linearQuery(apiKey, query);
    return true;
  } catch {
    return false;
  }
}

// Get current user info
export async function getCurrentUser(apiKey: string) {
  const query = `
    query {
      viewer {
        id
        name
        email
      }
    }
  `;
  const data = await linearQuery(apiKey, query);
  return data.viewer;
}
