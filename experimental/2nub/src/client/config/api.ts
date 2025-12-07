// API configuration for the frontend
// Uses environment variables with fallbacks for different environments

// Get the API base URL from environment variable or use default
const getApiBaseUrl = (): string => {
  // In development, default to localhost:8000 where Express server runs
  // In production, this should be set to the actual backend URL
  const defaultUrl = 'http://localhost:8000';
  
  // Use REACT_APP_ prefix for Create React App / Parcel compatibility
  const envUrl = process.env.REACT_APP_API_BASE_URL || process.env.API_BASE_URL;
  
  return envUrl || defaultUrl;
};

export const API_BASE_URL = getApiBaseUrl();

// Utility function to build full API URLs
export const buildApiUrl = (path: string): string => {
  // Remove leading slash if present to avoid double slashes
  const cleanPath = path.startsWith('/') ? path.slice(1) : path;
  return `${API_BASE_URL}/${cleanPath}`;
};

// WebSocket URL configuration
export const getWebSocketUrl = (): string => {
  const baseUrl = API_BASE_URL;
  // Convert HTTP(S) to WS(S)
  const wsUrl = baseUrl.replace(/^http/, 'ws');
  return wsUrl;
};