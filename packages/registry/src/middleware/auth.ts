import { NextFunction, Request, Response } from 'express';
import jwt, { JwtPayload } from 'jsonwebtoken';
import { logger } from '../server';

if (process.env.NODE_ENV === 'production' && !process.env.JWT_SECRET) {
    throw new Error('JWT_SECRET must be set in production');
}

export const JWT_SECRET = process.env.JWT_SECRET || 'your-secret-key';

export interface HomeJwtPayload extends JwtPayload {
    userId: string;
    username: string;
}

export interface AuthRequest extends Request {
    user?: {
        userId: string;
        username: string;
    };
}

function isHomeJwtPayload(value: unknown): value is HomeJwtPayload {
    return (
        typeof value === 'object' &&
        value !== null &&
        typeof (value as HomeJwtPayload).userId === 'string' &&
        typeof (value as HomeJwtPayload).username === 'string'
    );
}

export function authMiddleware(
    req: Request,
    res: Response,
    next: NextFunction
): void {
    try {
        const authHeader = req.headers.authorization;

        if (!authHeader || !authHeader.startsWith('Bearer ')) {
            res.status(401).json({ error: 'No token provided' });
            return;
        }

        const token = authHeader.substring(7);

        try {
            const decoded = jwt.verify(token, JWT_SECRET);
            if (!isHomeJwtPayload(decoded)) {
                res.status(401).json({ error: 'Invalid token payload' });
                return;
            }
            (req as AuthRequest).user = {
                userId: decoded.userId,
                username: decoded.username,
            };
            next();
        } catch (error) {
            logger.warn('Invalid token', { error });
            res.status(401).json({ error: 'Invalid token' });
        }
    } catch (error) {
        logger.error('Auth middleware error', { error });
        res.status(500).json({ error: 'Authentication failed' });
    }
}
