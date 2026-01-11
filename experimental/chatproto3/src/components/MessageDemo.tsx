import React, { useState } from 'react';

interface MessageDemoProps {
    hintChannelOwner?: string;
    channelNsid: string;
}

export default function MessageDemo({
    hintChannelOwner,
    channelNsid,
}: MessageDemoProps) {
    if (!hintChannelOwner) {
        return <p>Please provide a hintChannelOwner.</p>
    }
    return <div>Placeholder</div>
}