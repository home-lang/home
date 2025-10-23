import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { logger } from '../server';

const JWT_SECRET = process.env.JWT_SECRET || 'your-secret-key';

export interface AuthRequest extends Request {
    user?: {
        userId: string;
        username: string;
    };
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
            const decoded = jwt.verify(token, JWT_SECRET) as any;
            (req as AuthRequest).user = {
                userId: decoded.userId,
                username: decoded.username
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
