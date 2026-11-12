// Launch timing rig: a TCP proxy that holds every chunk for a fixed time in
// each direction, so the simulator reaches the local journal over something
// like a phone's link instead of loopback. With the default 75 ms each way
// a request and its answer take 150 ms longer, and a new connection pays it
// once more for the handshake.
//
// SIGUSR1 stalls the connections open at that moment: they stay open and
// carry nothing more, like a socket the network dropped while the phone
// slept. Connections made afterwards work as usual.
//
// Run: node latency-proxy.mjs [listen port] [journal port] [ms each way]
import net from 'node:net';

const listenPort = Number(process.argv[2] ?? 9821);
const targetPort = Number(process.argv[3] ?? 9820);
const delayMs = Number(process.argv[4] ?? 75);

const live = new Set();
process.on('SIGUSR1', () => {
  for (const pair of live) pair.stalled = true;
  console.log(`stalled ${live.size} connections`);
});

function relay(from, to, pair) {
  // One timer per chunk, all with the same delay, so chunks keep their order.
  from.on('data', (chunk) => setTimeout(() => { if (!pair.stalled && !to.destroyed) to.write(chunk); }, delayMs));
  from.on('end', () => setTimeout(() => to.end(), delayMs));
  from.on('error', () => to.destroy());
  from.on('close', () => setTimeout(() => to.destroy(), delayMs + 50));
}

net.createServer((client) => {
  const upstream = net.connect(targetPort, '127.0.0.1');
  const pair = { stalled: false };
  live.add(pair);
  client.on('close', () => live.delete(pair));
  relay(client, upstream, pair);
  relay(upstream, client, pair);
}).listen(listenPort, '127.0.0.1', () => console.log(`proxy ${listenPort} -> ${targetPort}, ${delayMs} ms each way`));
