# serves a directory over HTTP for test/run, plus S3 through moto when installed;
# prints "<http port> <s3 port or ->" once ready and logs "<method> <path> <status>" per request
#   <dir>/bare/<file>  serves <dir>/<file> with no Last-Modified header
#   <dir>/nohead/<file>  refuses HEAD requests
import http.server, io, os, re, sys, threading

log = threading.Lock()


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        return super().translate_path(re.sub(r'/(bare|nohead)/', '/', path, count=1))

    def do_HEAD(self):
        if '/nohead/' in self.path:
            return self.send_error(405)
        super().do_HEAD()

    def send_header(self, key, value):
        if not ('/bare/' in self.path and key == 'Last-Modified'):
            super().send_header(key, value)

    def end_headers(self):
        self.send_header('Accept-Ranges', 'bytes')
        super().end_headers()

    def send_head(self):
        path = self.translate_path(self.path)
        m = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        if not m or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        start, end = int(m[1]), min(int(m[2] or size - 1), size - 1)
        with open(path, 'rb') as f:
            f.seek(start)
            body = f.read(end - start + 1)
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Last-Modified', self.date_time_string(int(os.path.getmtime(path))))
        self.end_headers()
        return io.BytesIO(body)

    def log_request(self, code='-', size='-'):
        with log:
            print(self.command, self.path, int(code), flush=True)

    def log_message(self, *args):
        pass


def s3():
    try:
        from moto.server import ThreadedMotoServer
    except ImportError:
        return '-'
    server = ThreadedMotoServer(ip_address='127.0.0.1', port=0, verbose=False)
    server.start()
    return server._server.server_port


os.chdir(sys.argv[1])
httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(httpd.server_port, s3(), flush=True)
httpd.serve_forever()
