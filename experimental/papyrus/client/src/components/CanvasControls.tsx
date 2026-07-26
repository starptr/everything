import { motion } from "framer-motion";
import { Plus } from "lucide-react";
import { useStore } from "../stores/useStore";

export function CanvasControls() {
  const { setAddAgentModalOpen } = useStore();

  return (
    <div className="absolute bottom-4 right-4 z-10 flex flex-col gap-2">
      <motion.button
        onClick={() => setAddAgentModalOpen(true)}
        className="w-14 h-14 rounded-full bg-inverse shadow-lg flex items-center justify-center text-inverse-content hover:bg-inverse/90 transition-colors"
        whileHover={{ scale: 1.05 }}
        whileTap={{ scale: 0.95 }}
        title="New Workstream"
      >
        <Plus className="w-6 h-6" />
      </motion.button>
    </div>
  );
}
