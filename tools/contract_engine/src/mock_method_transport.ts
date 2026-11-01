import {METHODS,type IncomingMessage,type Server} from 'node:http';
import type {Socket} from 'node:net';
import {SourceError} from './document';

const recognizedMethods=Object.freeze([...METHODS]);
const methodToken=/^[-!#$%&'*+.^_`|~0-9A-Za-z]+$/;
export const maximumMockMethodBytes=16*1024;

/** Node's pinned HTTP parser recognizes a closed method inventory. Only its
 * first method token is adapted; its original connection listener still owns
 * all request-target, header, framing and body parsing. OAS 3.2 §4.9.1 and
 * RFC 9110 §9.1 require the original method's capitalization to survive.
 * Custom-method captures use one request per connection, so another method
 * never bypasses this bounded entry point through a reused parser. */
export class MockMethodTransport {
    private readonly pending=new Set<Socket>();
    private readonly methods=new WeakMap<Socket,string>();

    constructor(server:Server,private readonly enabled:boolean) {
        if(!enabled)return;
        const listeners=server.listeners('connection');
        if(listeners.length!==1||typeof listeners[0]!=='function')
            throw new SourceError('mock.method.parser','The pinned HTTP parser connection owner is unavailable');
        const connect=listeners[0];
        server.removeAllListeners('connection');
        server.maxRequestsPerSocket=1;
        server.prependListener('request',(request,response)=>{
            response.shouldKeepAlive=false;
            response.setHeader('connection','close');
            response.once('finish',()=>request.socket.end());
        });
        server.on('connection',socket=>{
            this.pending.add(socket);
            let buffer=Buffer.alloc(0),finished=false;
            const timer=setTimeout(()=>reject(408),5000);
            timer.unref();
            const clear=()=>{
                clearTimeout(timer);
                socket.off('data',data);
                buffer=Buffer.alloc(0);
            };
            const closed=()=>{clear();this.pending.delete(socket);};
            const failed=()=>{clear();socket.destroy();};
            const reject=(status:number)=>{
                if(finished)return;
                finished=true;clear();
                const reason=status===408?'Request Timeout':status===431?'Request Header Fields Too Large':'Bad Request';
                socket.end(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`,()=>socket.destroy());
            };
            const data=(chunk:Buffer)=>{
                buffer=Buffer.concat([buffer,chunk]);
                let start=0;
                while(buffer[start]===13){
                    if(buffer.length<start+2)return;
                    if(buffer[start+1]!==10||start>=16){reject(400);return;}
                    start+=2;
                }
                if(start===buffer.length)return;
                const end=buffer.indexOf(32,start);
                const token=buffer.subarray(start,end<0?undefined:end).toString('latin1');
                if(token.length>maximumMockMethodBytes){reject(431);return;}
                if(!methodToken.test(token)){reject(400);return;}
                if(end<0)return;
                const method=token;
                const bytes=recognizedMethods.includes(method)?buffer:
                    Buffer.concat([buffer.subarray(0,start),Buffer.from('POST'),buffer.subarray(end)]);
                finished=true;socket.pause();clear();
                this.methods.set(socket,method);
                this.pending.delete(socket);
                // This is the original listener captured from this newly
                // created server, with its original receiver and socket.
                try{
                    Reflect.apply(connect,server,[socket]);
                    socket.off('error',failed);
                    socket.unshift(bytes);
                    socket.resume();
                }catch(error){
                    socket.destroy(error instanceof Error?error:
                        new SourceError('mock.method.parser','The original HTTP parser could not own this connection'));
                }
            };
            socket.once('close',closed);
            socket.once('error',failed);
            socket.on('data',data);
            socket.resume();
        });
    }

    method(request:IncomingMessage):string {
        const method=this.enabled?this.methods.get(request.socket):request.method;
        if(typeof method!=='string'||!methodToken.test(method))
            throw new SourceError('mock.method.owner','The request omitted its original captured HTTP method');
        return method;
    }

    close():void {
        for(const socket of this.pending)socket.destroy();
        this.pending.clear();
    }
}
