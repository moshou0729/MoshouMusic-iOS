// 网易云音乐源脚本 (weapi 自实现)
//   加密: 标准 weapi (AES-128-CBC x2 + RSA), AES 走桥接, RSA 用 BigInt 自实现
//   搜索/榜单/播放/歌词均采用官方 weapi 接口
;(function() {
    const source = 'wy'

    lx.send(EVENT_NAMES.inited, {
        sources: ['wy'],
        qualities: ['128k', '320k', 'flac']
    })

    lx.on(EVENT_NAMES.request, function(data, callback) {
        const { source: src, action, info } = data
        if (src !== source) return

        switch (action) {
            case 'musicSearch': handleSearch(info, callback); break
            case 'musicUrl':    handleMusicUrl(info, callback); break
            case 'lyric':       handleLyric(info, callback); break
            case 'pic':         handlePic(info, callback); break
            case 'musicBoard':  handleBoard(info, callback); break
            default: callback({ message: '未知操作: ' + action }, null)
        }
    })

    const HEADERS = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 14_7_1 like Mac OS X) AppleWebKit/605.1.15',
        'Referer': 'https://music.163.com/',
        'Content-Type': 'application/x-www-form-urlencoded'
    }

    // ==================== weapi 加密 ====================
    const IV = '0102030405060708'
    const PRESET = '0CoJUm6Qyw8W8jud'
    const RANDOM_KEY = 'aib7W0y0w9RqU9dZ'
    const MODULUS = '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7'
    const N = BigInt('0x' + MODULUS)
    const E = BigInt(65537)

    function modpow(b, e, m) {
        let r = BigInt(1)
        b = b % m
        while (e > BigInt(0)) {
            if (e & BigInt(1)) r = (r * b) % m
            e = e >> BigInt(1)
            b = (b * b) % m
        }
        return r
    }

    function bytesToBase64(bytes) {
        const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
        let out = ''
        for (let i = 0; i < bytes.length; i += 3) {
            const b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2]
            out += table[b0 >> 2]
            out += table[((b0 & 3) << 4) | (b1 !== undefined ? (b1 >> 4) : 0)]
            out += b1 !== undefined ? table[((b1 & 15) << 2) | (b2 !== undefined ? (b2 >> 6) : 0)] : '='
            out += b2 !== undefined ? table[b2 & 63] : '='
        }
        return out
    }

    function rsaEncrypt(rawKey) {
        const rev = rawKey.split('').reverse().join('')
        let m = BigInt(0)
        for (let i = 0; i < rev.length; i++) {
            m = (m << BigInt(8)) | BigInt(rev.charCodeAt(i))
        }
        const c = modpow(m, E, N)
        const buf = new Array(128).fill(0)
        let t = c
        for (let i = 127; i >= 0; i--) {
            buf[i] = Number(t & BigInt(0xff))
            t = t >> BigInt(8)
        }
        return bytesToBase64(buf)
    }

    function weapi(obj) {
        const text = JSON.stringify(obj)
        const b64 = lx.utils.crypto.base64Encode(text)
        const c1 = lx.utils.crypto.aesCbc(b64, PRESET, IV)
        const params = lx.utils.crypto.aesCbc(c1, RANDOM_KEY, IV)
        const encSecKey = rsaEncrypt(RANDOM_KEY)
        return { params: params, encSecKey: encSecKey }
    }

    function enc(v) {
        return v.replace(/\+/g, '%2B').replace(/\//g, '%2F').replace(/=/g, '%3D')
    }

    function post(endpoint, obj, callback) {
        const w = weapi(obj)
        const body = 'params=' + enc(w.params) + '&encSecKey=' + enc(w.encSecKey)
        lx.request('https://music.163.com' + endpoint, {
            method: 'POST',
            headers: HEADERS,
            body: body,
            timeout: 15
        }, function(err, resp) {
            if (err) { callback(err, null); return }
            try {
                const result = JSON.parse(resp.body)
                if (result.code && result.code !== 200) {
                    callback({ message: '网易云接口返回 code=' + result.code }, null)
                    return
                }
                callback(null, result)
            } catch (e) {
                callback({ message: '网易云接口返回非 JSON: HTTP ' + resp.statusCode }, null)
            }
        })
    }

    function parseBody(body) {
        try { return JSON.parse(body) } catch (e) { return null }
    }

    function mapSong(item) {
        const artists = (item.artists || item.ar || []).map(function(a) { return a.name }).join('/')
        const album = item.album || item.al || {}
        const dur = (item.duration || item.dt || 0) / 1000
        return {
            songmid: String(item.id || ''),
            name: item.name || '未知歌曲',
            singer: artists || '未知歌手',
            albumName: album.name || '',
            albumId: String(album.id || ''),
            img: album.picUrl || '',
            interval: Math.round(dur),
            quality: '320k'
        }
    }

    // ==================== 搜索 ====================
    function handleSearch(info, callback) {
        const keyword = info.keyword || ''
        const page = info.page || 1
        post('/weapi/cloudsearch/get/web?csrf_token=', {
            csrf_token: '',
            hlpretag: '<span class="s-fc7">',
            hlposttag: '</span>',
            s: keyword,
            type: 1,
            offset: (page - 1) * 30,
            total: true,
            limit: 30
        }, function(err, result) {
            if (err) { callback(err, null); return }
            const songs = (result.result && result.result.songs) || []
            const list = songs.map(mapSong).filter(function(s) { return s.songmid && s.name })
            callback(null, { list: list, total: list.length })
        })
    }

    // ==================== 播放链接 ====================
    function handleMusicUrl(info, callback) {
        const id = parseInt(info.songmid, 10)
        if (!id) { callback({ message: '无效的歌曲ID' }, null); return }
        post('/weapi/song/enhance/player/url/v1?csrf_token=', {
            ids: [id],
            level: 'standard',
            encodeType: 'mp3',
            csrf_token: ''
        }, function(err, result) {
            if (err) { callback(err, null); return }
            const arr = result.data || []
            const url = arr.length ? arr[0].url : ''
            if (url) callback(null, { url: url })
            else callback({ message: '网易云未返回播放链接(可能下架/需版权)' }, null)
        })
    }

    // ==================== 歌词 ====================
    function handleLyric(info, callback) {
        const id = parseInt(info.songmid, 10)
        if (!id) { callback(null, { lyric: '', tlyric: '' }); return }
        post('/weapi/song/lyric?csrf_token=', {
            id: id,
            lv: true,
            tv: true,
            csrf_token: ''
        }, function(err, result) {
            if (err) { callback(null, { lyric: '', tlyric: '' }); return }
            const lrc = (result.lrc && result.lrc.lyric) || ''
            const tlrc = (result.tlyric && result.tlyric.lyric) || ''
            callback(null, { lyric: lrc, tlyric: tlrc })
        })
    }

    // ==================== 封面 ====================
    function handlePic(info, callback) {
        // 搜索时已带封面; pic 动作传入 songmid 时无法回溯, 返回空让上层用搜索封面
        callback(null, { url: '' })
    }

    // ==================== 推荐 (云音乐热歌榜 playlist 3778678) ====================
    function handleBoard(info, callback) {
        post('/weapi/v3/playlist/detail?csrf_token=', {
            id: 3778678,
            n: 1000,
            csrf_token: ''
        }, function(err, result) {
            if (err) { callback(err, null); return }
            const tracks = (result.playlist && result.playlist.tracks) || []
            const list = tracks.map(mapSong).filter(function(s) { return s.songmid && s.name })
            callback(null, { list: list.slice(0, 30), total: list.length })
        })
    }
})()
