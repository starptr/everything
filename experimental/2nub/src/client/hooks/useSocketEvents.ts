import { useSocketEventContext } from '../contexts/SocketEventContext';

export const useSocketEvents = () => {
  return useSocketEventContext();
};