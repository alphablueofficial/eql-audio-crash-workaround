Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not ('EqlMidiProbe.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace EqlMidiProbe
{
    public static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct MIDIOUTCAPS
        {
            public ushort wMid;
            public ushort wPid;
            public uint vDriverVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string szPname;
            public ushort wTechnology;
            public ushort wVoices;
            public ushort wNotes;
            public ushort wChannelMask;
            public uint dwSupport;
        }

        [DllImport("winmm.dll")]
        private static extern uint midiOutGetNumDevs();

        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern uint midiOutGetDevCapsW(UIntPtr deviceId, out MIDIOUTCAPS caps, uint capsSize);

        public static object[] Enumerate()
        {
            var rows = new List<object>();
            uint count = midiOutGetNumDevs();
            uint size = (uint)Marshal.SizeOf(typeof(MIDIOUTCAPS));
            for (uint i = 0; i < count; i++)
            {
                MIDIOUTCAPS caps;
                uint result = midiOutGetDevCapsW((UIntPtr)i, out caps, size);
                rows.Add(new { id = i, name = caps.szPname ?? "", result = result });
            }
            return rows.ToArray();
        }
    }
}
'@
}

[ordered]@{
    schema = 'eql-midi-probe-v1'
    processBitness = if ([Environment]::Is64BitProcess) { 64 } else { 32 }
    devices = [EqlMidiProbe.NativeMethods]::Enumerate()
} | ConvertTo-Json -Depth 5 -Compress
